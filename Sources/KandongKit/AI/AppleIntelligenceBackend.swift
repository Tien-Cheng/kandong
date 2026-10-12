import Foundation
import FoundationModels
import ImageIO

/// Why Apple Intelligence can't answer on this Mac.
public enum AppleIntelligenceUnavailability: Equatable, Sendable {
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unknown

    init(_ reason: SystemLanguageModel.Availability.UnavailableReason) {
        switch reason {
        case .deviceNotEligible: self = .deviceNotEligible
        case .appleIntelligenceNotEnabled: self = .notEnabled
        case .modelNotReady: self = .modelNotReady
        @unknown default: self = .unknown
        }
    }

    public var message: String {
        switch self {
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
        case .notEnabled: "Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
        case .modelNotReady: "The Apple Intelligence model is still downloading. Try again in a few minutes."
        case .unknown: "Apple Intelligence isn't available right now."
        }
    }

    /// Opens the Apple Intelligence pane of System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}

/// The calls into the on-device model, replaceable in tests.
struct AppleModelClient: Sendable {
    var unavailability: @Sendable () -> AppleIntelligenceUnavailability?
    /// The JSON object so far, matching the schema, after each step of guided generation (default guardrails).
    var structured: @Sendable (_ prompt: Prompt, _ system: String, _ schema: GenerationSchema) -> AsyncThrowingStream<String, Error>
    /// The plain-text reply so far, after each step of generation (permissive guardrails).
    var snapshots: @Sendable (_ prompt: Prompt, _ system: String) -> AsyncThrowingStream<String, Error>

    static let options = GenerationOptions(temperature: 0.2)

    static let live = AppleModelClient(
        unavailability: { AppleIntelligenceBackend.unavailability },
        structured: { prompt, system, schema in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
                        // Each partial snapshot is itself complete JSON, e.g. {"translation": "Chinese class at"}.
                        for try await snapshot in session.streamResponse(to: prompt, schema: schema, options: options) {
                            continuation.yield(snapshot.rawContent.jsonString)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        },
        snapshots: { prompt, system in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                        let session = LanguageModelSession(model: model, instructions: system)
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    )
}

/// Turns "the reply so far" snapshots into the text to append. Compares Unicode scalars, so a
/// combining tone mark that extends the last character is sent on its own instead of looking
/// like a rewrite.
struct SnapshotDeltas {
    private var sent: [Unicode.Scalar] = []

    mutating func next(_ snapshot: String) -> String {
        let scalars = Array(snapshot.unicodeScalars)
        defer { sent = scalars }
        if scalars.starts(with: sent) {
            var delta = String.UnicodeScalarView()
            delta.append(contentsOf: scalars[sent.count...])
            return String(delta)
        }
        // The model revised earlier text. A stream can't take text back, so show the new version
        // as a fresh paragraph (only display streams get here; JSON replies are taken whole).
        return "\n\n" + snapshot
    }
}

/// Apple's on-device Foundation Model. Never uses Private Cloud Compute (see ADR 0004).
public struct AppleIntelligenceBackend: AIBackend {
    public let label = BackendConfig.appleIntelligence.name

    /// The on-device model misses most 多音字 and sometimes "corrects" a right reading into a wrong
    /// one (see `KandongEval`), so it only translates and the dictionary readings stand.
    public let correctsReadings = false
    let client: AppleModelClient

    public init() {
        client = .live
    }

    init(client: AppleModelClient) {
        self.client = client
    }

    /// Nil when the model can answer, else why not.
    public static var unavailability: AppleIntelligenceUnavailability? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason): AppleIntelligenceUnavailability(reason)
        @unknown default: .unknown
        }
    }

    /// Loads the model ahead of a request so the first reply comes sooner.
    public static func prewarm() {
        guard unavailability == nil else { return }
        LanguageModelSession().prewarm()
    }

    public func status() async -> BackendStatus {
        switch client.unavailability() {
        case nil: .ready("On this Mac")
        case .deviceNotEligible: .unavailable(AppleIntelligenceUnavailability.deviceNotEligible.message)
        case .notEnabled: .needsSetup(AppleIntelligenceUnavailability.notEnabled.message,
                                      fix: .openURL(AppleIntelligenceUnavailability.settingsURL, label: "Open Settings"))
        case let reason?: .needsSetup(reason.message)
        }
    }

    public func supportsImages() async -> Bool {
        Self.unavailability == nil && SystemLanguageModel.default.capabilities.contains(.vision)
    }

    /// Counts the prompt's tokens and leaves room for the reply (Chinese is about a token a character).
    public func fits(_ request: AIRequest) async -> Bool? {
        guard Self.unavailability == nil, request.image == nil else { return nil }
        let model = SystemLanguageModel.default
        do {
            var tokens = try await model.tokenCount(for: Instructions(request.system))
            tokens += try await model.tokenCount(for: Prompt(request.user))
            if let schema = request.schema { tokens += try await model.tokenCount(for: try Self.generationSchema(from: schema)) }
            return tokens + request.expectedReplyLength + Self.overhead <= model.contextSize
        } catch {
            return nil
        }
    }

    /// Slack for the chat template and rounding.
    static let overhead = 128

    public func snapshots(of request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = client.unavailability() { throw BackendError.appleIntelligenceUnavailable(reason) }
                    let prompt = try Self.prompt(for: request)
                    if let schema = request.schema {
                        let generationSchema = try Self.generationSchema(from: schema)
                        do {
                            for try await snapshot in client.structured(prompt, request.system, generationSchema) {
                                continuation.yield(snapshot)
                            }
                        } catch let error as LanguageModelError where Self.isRefusal(error) {
                            // Guided generation uses the default guardrails; retry once as plain text with the
                            // permissive ones (the system prompt already asks for JSON). Its snapshots replace
                            // any partial reply so far.
                            for try await snapshot in client.snapshots(prompt, request.system) { continuation.yield(snapshot) }
                        }
                    } else {
                        for try await snapshot in client.snapshots(prompt, request.system) { continuation.yield(snapshot) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.backendError(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let snapshots = snapshots(of: request)
        let structured = request.schema != nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if structured {
                        // JSON is taken whole, so it is never stitched together from revised snapshots.
                        var reply = ""
                        for try await snapshot in snapshots { reply = snapshot }
                        continuation.yield(reply)
                    } else {
                        var deltas = SnapshotDeltas()
                        for try await snapshot in snapshots {
                            let delta = deltas.next(snapshot)
                            if !delta.isEmpty { continuation.yield(delta) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func prompt(for request: AIRequest) throws -> Prompt {
        guard let data = request.image else { return Prompt(request.user) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BackendError.failed("Couldn't read the image.")
        }
        return Prompt {
            request.user
            Attachment(image)
        }
    }

    // MARK: Errors

    static func isRefusal(_ error: LanguageModelError) -> Bool {
        switch error {
        case .guardrailViolation, .refusal: true
        default: false
        }
    }

    static func backendError(from error: Error) -> Error {
        switch error {
        case let error as LanguageModelError:
            switch error {
            case .contextSizeExceeded: return BackendError.contextTooLong
            case .guardrailViolation, .refusal: return BackendError.refused(name: "Apple Intelligence")
            case .rateLimited(let info):
                let when = info.resetDate.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? " Try again shortly."
                return BackendError.failed("Apple Intelligence is busy." + when)
            case .unsupportedLanguageOrLocale:
                return BackendError.failed("Apple Intelligence doesn't support this language.")
            case .timeout:
                return BackendError.failed("Apple Intelligence took too long to answer.")
            default:
                return BackendError.failed(error.localizedDescription)
            }
        case is SystemLanguageModel.Error:
            return BackendError.appleIntelligenceUnavailable(.modelNotReady)
        default:
            return error
        }
    }

    // MARK: Schemas

    /// Converts the JSON Schema subset `Prompts` uses into a schema for guided generation.
    public static func generationSchema(from json: JSONValue) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(from: json, name: json["title"]?.string ?? "Reply"), dependencies: [])
    }

    static func dynamicSchema(from json: JSONValue, name: String) throws -> DynamicGenerationSchema {
        switch json["type"]?.string {
        case "object":
            guard case .object(let properties)? = json["properties"] else {
                throw BackendError.failed("Schema object \(name) has no properties")
            }
            let required = json["required"]?.array?.compactMap(\.string) ?? []
            // Properties are generated in this order: required ones as listed, then the rest.
            let order = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
            return DynamicGenerationSchema(name: name, properties: try order.map { key in
                DynamicGenerationSchema.Property(
                    name: key,
                    schema: try dynamicSchema(from: properties[key]!, name: properties[key]?["title"]?.string ?? "\(name)_\(key)"),
                    isOptional: !required.contains(key)
                )
            })
        case "array":
            guard let items = json["items"] else { throw BackendError.failed("Schema array \(name) has no items") }
            return DynamicGenerationSchema(arrayOf: try dynamicSchema(from: items, name: items["title"]?.string ?? "\(name)_item"))
        case "string": return DynamicGenerationSchema(type: String.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default:
            throw BackendError.failed("Unsupported schema type at \(name): \(json["type"]?.string ?? "none")")
        }
    }
}
