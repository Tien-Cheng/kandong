import Foundation

/// One prompt to a Backend.
public struct AIRequest: Sendable {
    public var system: String
    public var user: String
    /// PNG data for image Sources (Backends without vision never receive one).
    public var image: Data?
    /// When set, the reply must be one JSON object matching this schema.
    public var schema: JSONValue?
    /// Roughly how many characters the reply will be, so Backends with a small context can leave room for it.
    public var expectedReplyLength: Int

    public init(system: String, user: String, image: Data? = nil, schema: JSONValue? = nil, expectedReplyLength: Int = 500) {
        self.system = system
        self.user = user
        self.image = image
        self.schema = schema
        self.expectedReplyLength = expectedReplyLength
    }
}

/// The AI provider answering a Lookup.
public protocol AIBackend: Sendable {
    var kind: BackendKind { get }
    /// Short label for the panel badge, e.g. "Codex · gpt-6.1-sol".
    var label: String { get }
    func supportsImages() async -> Bool
    /// Whether to ask this Backend to correct dictionary readings in context (多音字).
    var correctsReadings: Bool { get }
    /// Whether the request and its reply fit in the model's context; nil when the Backend can't
    /// tell, in which case it reports `BackendError.contextTooLong` if it doesn't.
    func fits(_ request: AIRequest) async -> Bool?
    /// Streams the reply as text deltas.
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error>
}

extension AIBackend {
    public var correctsReadings: Bool { true }

    public func fits(_ request: AIRequest) async -> Bool? { nil }

    /// The whole reply as one string.
    public func complete(_ request: AIRequest) async throws -> String {
        var text = ""
        for try await delta in respond(to: request) { text += delta }
        return text
    }
}

public enum BackendError: LocalizedError, Equatable {
    case codexNotInstalled
    case codexNotSignedIn
    case serverUnavailable(name: String, url: String, hint: String)
    case noModel(name: String, hint: String)
    case http(status: Int, body: String)
    case protocolError(String)
    case failed(String)
    case badResponse(String)
    case appleIntelligenceUnavailable(AppleIntelligenceUnavailability)
    /// The prompt doesn't fit in the model's context window.
    case contextTooLong
    /// The model declined to answer (content guardrails).
    case refused(name: String)
    /// The model gave the text back, or only part of it, instead of translating it all.
    case untranslated

    public var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            "Codex CLI not found. Install it with `brew install codex` (or set its path in Settings)."
        case .codexNotSignedIn:
            "Codex is not signed in. Run `codex login` in a terminal."
        case .serverUnavailable(let name, let url, let hint):
            "\(name) isn't reachable at \(url). \(hint)"
        case .noModel(let name, let hint):
            "\(name) has no model available. \(hint)"
        case .http(let status, let body):
            "The AI server returned HTTP \(status): \(body.prefix(300))"
        case .protocolError(let message):
            "Unexpected reply from Codex: \(message)"
        case .failed(let message):
            message
        case .badResponse(let message):
            "Couldn't read the AI's answer: \(message)"
        case .appleIntelligenceUnavailable(let reason):
            reason.message
        case .contextTooLong:
            "The text is too long for this model."
        case .untranslated:
            "The AI didn't translate all of the text."
        case .refused(let name):
            "\(name) declined this text — try another backend."
        }
    }
}
