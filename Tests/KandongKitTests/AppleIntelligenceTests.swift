import CoreGraphics
import CoreText
import Foundation
import FoundationModels
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KandongKit

@Suite struct AppleIntelligenceSchemaTests {
    func encoded(_ schema: JSONValue) throws -> JSONValue {
        try JSONValue.decode(JSONEncoder().encode(AppleIntelligenceBackend.generationSchema(from: schema)))
    }

    @Test func convertsLearnSchema() throws {
        let json = try encoded(Prompts.learnSchema)
        #expect(json["type"] == "object")
        // Translation is generated first.
        #expect(json["x-order"] == ["translation", "readingCorrections"])
        #expect(Set(json["required"]?.array ?? []) == ["translation", "readingCorrections"])
        #expect(json["properties"]?["translation"]?["type"] == "string")
        #expect(json["properties"]?["readingCorrections"]?["type"] == "array")
        guard case .object(let defs)? = json["$defs"], let item = defs.values.first else {
            Issue.record("correction item should be a named definition: \(json)")
            return
        }
        #expect(item["x-order"] == ["word", "pinyin"])
    }

    @Test func convertsReadingChoicesToEnums() throws {
        let schema = Prompts.choiceSchema([ReadingChoice(key: "w1", word: "还", options: ["huán", "hái"])])
        let json = try encoded(schema)
        #expect(json["x-order"] == ["translation", "readings"])
        #expect("\(json)".contains("hái") && "\(json)".contains("huán"), "the options survive: \(json)")
    }

    @Test func convertsReverseSchema() throws {
        let json = try encoded(Prompts.reverseSchema)
        #expect(json["x-order"] == ["chinese", "note"])
    }

    @Test func marksUnlistedPropertiesOptional() throws {
        let json = try encoded(["type": "object", "required": ["a"], "properties": ["a": ["type": "string"], "b": ["type": "integer"]]])
        #expect(json["required"] == ["a"])
        #expect(json["x-order"] == ["a", "b"])
    }

    @Test func rejectsUnsupportedSchemas() {
        #expect(throws: BackendError.self) {
            try AppleIntelligenceBackend.generationSchema(from: ["type": "object", "properties": ["a": ["enum": ["x"]]]])
        }
    }

    @Test func mapsErrors() {
        let tooLong = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: ""))
        #expect(AppleIntelligenceBackend.backendError(from: tooLong) as? BackendError == .contextTooLong)
        let refusal = LanguageModelError.refusal(.init(explanation: "no", debugDescription: ""))
        #expect(AppleIntelligenceBackend.backendError(from: refusal) as? BackendError == .refused(name: "Apple Intelligence"))
        #expect(AppleIntelligenceBackend.isRefusal(.guardrailViolation(.init(debugDescription: ""))))
        #expect(!AppleIntelligenceBackend.isRefusal(tooLong))
    }
}

@Suite struct SnapshotDeltaTests {
    func deltas(_ snapshots: [String]) -> [String] {
        var converter = SnapshotDeltas()
        return snapshots.map { converter.next($0) }
    }

    @Test func sendsOnlyNewText() {
        #expect(deltas(["你", "你好", "你好", "你好！"]) == ["你", "好", "", "！"])
    }

    @Test func sendsCombiningMarksOnTheirOwn() {
        #expect(deltas(["n", "n\u{030C} hǎo"]).joined() == "n\u{030C} hǎo")
        #expect(deltas(["\r", "\r\n"]) == ["\r", "\n"])
    }

    @Test func showsARevisionAsANewParagraph() {
        #expect(deltas(["abc", "abX"]) == ["abc", "\n\nabX"])
    }
}

/// A stand-in for the on-device model that records what was asked of it.
private final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var structuredError: Error?
    /// Partial JSON sent before `structuredError` is thrown.
    var structuredBeforeError: [String] = []
    var snapshots = ["{\"translation\": \"Hi\"}"]
    var endless = false
    private(set) var snapshotStreamEnded = false

    var log: [String] { lock.withLock { calls } }
    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    var client: AppleModelClient {
        AppleModelClient(
            unavailability: { nil },
            structured: { _, _, _ in
                self.record("structured")
                let error = self.structuredError
                let before = self.structuredBeforeError
                return AsyncThrowingStream { continuation in
                    for snapshot in before { continuation.yield(snapshot) }
                    if let error { return continuation.finish(throwing: error) }
                    continuation.yield(#"{"translation": "Hel"}"#)
                    continuation.yield(#"{"translation": "Hello"}"#)
                    continuation.finish()
                }
            },
            snapshots: { _, _ in
                self.record("snapshots")
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        for snapshot in self.snapshots { continuation.yield(snapshot) }
                        while self.endless, !Task.isCancelled {
                            continuation.yield("…")
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        self.lock.withLock { self.snapshotStreamEnded = true }
                    }
                }
            }
        )
    }
}

@Suite struct AppleIntelligenceBackendTests {
    let learn = AIRequest(system: "s", user: "你好", schema: Prompts.translationSchema)

    @Test func structuredRepliesComeFromGuidedGeneration() async throws {
        let model = FakeModel()
        let reply = try await AppleIntelligenceBackend(client: model.client).complete(learn)
        #expect(reply == #"{"translation": "Hello"}"#)
        #expect(model.log == ["structured"])
    }

    @Test func streamsStructuredSnapshots() async throws {
        var snapshots: [String] = []
        for try await snapshot in AppleIntelligenceBackend(client: FakeModel().client).snapshots(of: learn) { snapshots.append(snapshot) }
        #expect(snapshots == [#"{"translation": "Hel"}"#, #"{"translation": "Hello"}"#])
    }

    @Test func retriesARefusalOnceAsPlainText() async throws {
        let model = FakeModel()
        model.structuredError = LanguageModelError.guardrailViolation(.init(debugDescription: ""))
        model.snapshots = [#"{"transl"#, #"{"translation": "Hi"}"#]
        let reply = try await AppleIntelligenceBackend(client: model.client).complete(learn)
        #expect(reply == #"{"translation": "Hi"}"#)
        #expect(model.log == ["structured", "snapshots"])
    }

    @Test func aRefusalPartwayReplacesThePartialReply() async throws {
        let model = FakeModel()
        model.structuredBeforeError = [#"{"translation": "Wh"}"#]
        model.structuredError = LanguageModelError.refusal(.init(explanation: "no", debugDescription: ""))
        model.snapshots = [#"{"transl"#, #"{"translation": "Hi"}"#]
        var snapshots: [String] = []
        for try await snapshot in AppleIntelligenceBackend(client: model.client).snapshots(of: learn) { snapshots.append(snapshot) }
        #expect(snapshots.last == #"{"translation": "Hi"}"#)
        #expect(try await AppleIntelligenceBackend(client: model.client).complete(learn) == #"{"translation": "Hi"}"#)
    }

    @Test func doesNotRetryOtherErrors() async {
        let model = FakeModel()
        model.structuredError = LanguageModelError.contextSizeExceeded(.init(contextSize: 10, tokenCount: 20, debugDescription: ""))
        await #expect(throws: BackendError.contextTooLong) {
            _ = try await AppleIntelligenceBackend(client: model.client).complete(learn)
        }
        #expect(model.log == ["structured"])
    }

    @Test func reportsUnavailabilityWithoutCallingTheModel() async {
        let model = FakeModel()
        var client = model.client
        client.unavailability = { .notEnabled }
        await #expect(throws: BackendError.appleIntelligenceUnavailable(.notEnabled)) {
            _ = try await AppleIntelligenceBackend(client: client).complete(learn)
        }
        #expect(model.log.isEmpty)
    }

    @Test func stopsGeneratingWhenTheReaderStops() async throws {
        let model = FakeModel()
        model.snapshots = ["a"]
        model.endless = true
        for try await _ in AppleIntelligenceBackend(client: model.client).respond(to: AIRequest(system: "s", user: "explain")) { break }
        for _ in 0..<200 where !model.snapshotStreamEnded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.snapshotStreamEnded)
    }
}

private let liveAppleIntelligence = ProcessInfo.processInfo.environment["KANDONG_LIVE"] == "1"
    && TestData.hasDictionary && AppleIntelligenceBackend.unavailability == nil

/// Real on-device round trips. Opt in: `KANDONG_LIVE=1 swift test --filter LiveAppleIntelligenceTests`.
@Suite(.enabled(if: liveAppleIntelligence))
struct LiveAppleIntelligenceTests {
    let engine = LookupEngine(analyzer: TestData.analyzer!, workspace: {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent("kandong-live-\(UUID().uuidString)"))
        try? workspace.ensureExists()
        try? workspace.upsertTerm(Term(chinese: "加油", english: "you've got this"))
        return workspace
    }())
    let backend = AppleIntelligenceBackend()

    @Test func learnKeepsMentionsAndTerms() async throws {
        let (translation, analysis) = try await engine.learn(engine.offline("明天考试，@Xiao Ming 加油！今晚再看一遍Quizlet"), backend: backend)
        #expect(translation.localizedCaseInsensitiveContains("got this"))
        #expect(translation.contains("@Xiao Ming"))
        // The small model sometimes lowercases brand names.
        #expect(translation.localizedCaseInsensitiveContains("Quizlet"))
        #expect(analysis.hasChinese)
    }

    @Test func reverseProducesChinese() async throws {
        let (reply, analysis) = try await engine.reverse("Shall we practise speaking together this weekend?", backend: backend)
        #expect(reply.chinese.containsHan)
        #expect(analysis.hasChinese)
    }

    @Test func explainStreamsMarkdown() async throws {
        var text = ""
        for try await delta in engine.explain("你跟老师沟通过了吗？", translation: nil, backend: backend) { text += delta }
        #expect(text.contains("过"))
    }

    @Test func readsTextInImages() async throws {
        #expect(await backend.supportsImages())
        let text = try await engine.transcribe(image: Self.png(of: "你好世界"), backend: backend)
        #expect(text.contains("你好"))
    }

    /// Renders black text on white as PNG data.
    static func png(of text: String) throws -> Data {
        let width = 480, height = 160
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 64, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 24, y: 56)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
