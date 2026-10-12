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
                return AsyncThrowingStream { continuation in
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

/// How well a Backend fixes context-dependent readings (多音字), asking for corrections whether or not
/// the Backend normally gets asked. Opt in: `KANDONG_LIVE=1 swift test --filter PolyphoneEval`.
///
/// Apple Intelligence on macOS 27.0.1 (AFM 3 Core Advanced), over two runs: fixed 1, missed 2–3 and turned
/// 1–3 readings wrong (e.g. 还给 huán → hái), which is why it has `correctsReadings = false`.
@Suite(.enabled(if: liveAppleIntelligence), .serialized)
struct PolyphoneEval {
    /// The bracketed character must read as given in context.
    static let cases: [(String, String)] = [
        ("我[还]没吃饭。", "hái"), ("请把书[还]给我。", "huán"),
        ("他是银[行]的职员。", "háng"), ("这样[行]不行？", "xíng"),
        ("他跑[得]很快。", "de"), ("你[得]早点儿来。", "děi"),
        ("孩子[长]大了。", "zhǎng"), ("这条河很[长]。", "cháng"),
        ("这个箱子很[重]。", "zhòng"), ("请你[重]新写一遍。", "chóng"),
        ("我明白[了]。", "le"), ("这件事我[了]解。", "liǎo"),
        ("他[着]急地问我。", "zháo"), ("墙上挂[着]一幅画。", "zhe"),
        ("他慢慢[地]走了。", "de"), ("[地]上很脏。", "dì"),
        ("这个菜很[便]宜。", "pián"), ("我[觉]得很好。", "jué"),
        ("我昨天睡了一[觉]。", "jiào"), ("[为]什么？", "wèi"),
        ("他成[为]了老师。", "wéi"), ("我的成绩很[差]。", "chà"),
        ("他去北京出[差]了。", "chāi"), ("我们[调]查一下。", "diào"),
        ("音[乐]很好听。", "yuè"),
    ]

    @Test func appleIntelligence() async throws {
        print(try await Self.run(backend: AppleIntelligenceBackend()).summary)
    }

    /// Baseline for comparison: `KANDONG_LIVE=1 KANDONG_EVAL_CODEX=1 swift test --filter PolyphoneEval`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KANDONG_EVAL_CODEX"] == "1"))
    func codex() async throws {
        print(try await Self.run(backend: CodexBackend(settings: CodexSettings())).summary)
    }

    struct Report {
        var fixed: [String] = [], missed: [String] = [], invented: [String] = [], kept = 0, otherCorrections: [String] = []
        var summary: String {
            """
            多音字 eval — kept right: \(kept), fixed: \(fixed.count), missed: \(missed.count), invented wrong: \(invented.count)
              fixed: \(fixed)
              missed: \(missed)
              invented: \(invented)
              corrections elsewhere (review by hand): \(otherCorrections)
            """
        }
    }

    static func run(backend: AIBackend) async throws -> Report {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        var report = Report()
        for (marked, expected) in cases {
            let offset = marked.distance(from: marked.startIndex, to: marked.firstIndex(of: "[")!)
            let sentence = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            let before = engine.offline(sentence)
            let request = Prompts.learn(text: sentence, analysis: before, context: "", terms: [], askForReadings: true)
            let reply = try Prompts.parseLearn(try await backend.complete(request))
            let after = engine.applyCorrections(reply.readingCorrections, to: before)
            let dictionary = reading(at: offset, in: before) ?? "?"
            let final = reading(at: offset, in: after) ?? "?"
            let label = "\(sentence) \(dictionary)→\(final) (want \(expected))"
            switch (same(dictionary, expected), same(final, expected)) {
            case (true, true): report.kept += 1
            case (false, true): report.fixed.append(label)
            case (false, false) where same(dictionary, final): report.missed.append(label)
            default: report.invented.append(label)
            }
            for segment in after.segments where segment.readingCorrected && !segment.text.contains(Array(sentence)[offset]) {
                report.otherCorrections.append("\(sentence): \(segment.text) → \(segment.pinyin)")
            }
        }
        return report
    }

    /// The pinyin of the character at `offset` in the analysed text.
    static func reading(at offset: Int, in analysis: OfflineAnalysis) -> String? {
        var position = 0
        for segment in analysis.segments {
            let length = segment.text.count
            if offset < position + length {
                let index = offset - position
                return segment.syllables.count == length ? Pinyin.display([segment.syllables[index]]) : nil
            }
            position += length
        }
        return nil
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.lowercased().trimmingCharacters(in: .whitespaces) == b.lowercased()
    }
}
