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

/// Apple's on-device Foundation Model. Never uses Private Cloud Compute (see ADR 0004).
public struct AppleIntelligenceBackend: AIBackend {
    public let kind = BackendKind.appleIntelligence
    public let label = BackendKind.appleIntelligence.displayName

    /// The on-device model misses most 多音字 and sometimes "corrects" a right reading into a wrong
    /// one (see `PolyphoneEval`), so it only translates and the dictionary readings stand.
    public let correctsReadings = false

    public init() {}

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

    public func supportsImages() async -> Bool {
        Self.unavailability == nil && SystemLanguageModel.default.capabilities.contains(.vision)
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailability { throw BackendError.appleIntelligenceUnavailable(reason) }
                    let prompt = try Self.prompt(for: request)
                    if let schema = request.schema {
                        do {
                            continuation.yield(try await Self.structured(prompt, system: request.system, schema: schema))
                        } catch let error as LanguageModelError {
                            // Guided generation uses the default guardrails; retry once as plain text with the
                            // permissive ones. The system prompt already asks for JSON.
                            guard Self.isRefusal(error) else { throw error }
                            try await Self.stream(prompt, system: request.system, into: continuation)
                        }
                    } else {
                        try await Self.stream(prompt, system: request.system, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.backendError(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let options = GenerationOptions(temperature: 0.2)

    private static func structured(_ prompt: Prompt, system: String, schema: JSONValue) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
        let response = try await session.respond(to: prompt, schema: try generationSchema(from: schema), options: options)
        return response.content.jsonString
    }

    /// Streams plain text; the framework yields the whole reply so far, so send only what is new.
    private static func stream(_ prompt: Prompt, system: String, into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: system)
        var sent = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let text = snapshot.content
            if text.hasPrefix(sent) {
                let delta = String(text.dropFirst(sent.count))
                if !delta.isEmpty { continuation.yield(delta) }
            } else {
                // The model revised earlier text; the stream can't take it back, so start a new paragraph.
                continuation.yield("\n\n" + text)
            }
            sent = text
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
