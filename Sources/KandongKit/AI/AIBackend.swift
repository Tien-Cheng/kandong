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
    /// The JSON property worth showing while the reply is still coming in, e.g. "translation".
    public var streamField: String?
    /// Sets how much the model may think before answering.
    public var task: AITask
    /// Called once if the model starts thinking before it answers, so the UI can say so.
    public var onThinking: (@Sendable () async -> Void)?

    public init(
        system: String, user: String, image: Data? = nil, schema: JSONValue? = nil, expectedReplyLength: Int = 500,
        streamField: String? = nil, task: AITask = .translate
    ) {
        self.system = system
        self.user = user
        self.image = image
        self.schema = schema
        self.expectedReplyLength = expectedReplyLength
        self.streamField = streamField
        self.task = task
    }
}

/// One thing the user can do to make a Backend ready.
public enum FixAction: Equatable, Sendable {
    /// Opens Kandong's ChatGPT connection flow; no terminal setup is needed.
    case connectChatGPT
    case openURL(URL, label: String)
    /// A command to paste into Terminal.
    case copyCommand(String, label: String)
    case openApp(bundleID: String, label: String)

    public var label: String {
        switch self {
        case .connectChatGPT: "Continue with ChatGPT"
        case .openURL(_, let label), .copyCommand(_, let label), .openApp(_, let label): label
        }
    }
}

/// Whether a Backend can answer right now, and if not, why.
public enum BackendStatus: Equatable, Sendable {
    case ready(String)
    case needsSetup(String, fix: FixAction? = nil)
    case unavailable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .ready(let message), .needsSetup(let message, _), .unavailable(let message): message
        }
    }

    public var fix: FixAction? {
        if case .needsSetup(_, let fix) = self { return fix }
        return nil
    }
}

/// The AI answering a Lookup.
public protocol AIBackend: Sendable {
    /// Short label for the panel badge, e.g. "ChatGPT · gpt-6.1-sol".
    var label: String { get }
    func supportsImages() async -> Bool
    /// How this Backend may change dictionary readings for the context (多音字).
    var readingMode: ReadingMode { get }
    /// Whether the request and its reply fit in the model's context; nil when the Backend can't
    /// tell, in which case it reports `BackendError.contextTooLong` if it doesn't.
    func fits(_ request: AIRequest) async -> Bool?
    /// Checks the Backend can answer, without sending a Lookup.
    func status() async -> BackendStatus
    /// Streams the reply as text deltas.
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error>
    /// Streams the whole reply so far after each step; the last one is the reply.
    func snapshots(of request: AIRequest) -> AsyncThrowingStream<String, Error>
}

extension AIBackend {
    public var readingMode: ReadingMode { .free }

    public func fits(_ request: AIRequest) async -> Bool? { nil }

    public func status() async -> BackendStatus { .ready("") }

    public func snapshots(of request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let deltas = respond(to: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var text = ""
                    for try await delta in deltas {
                        text += delta
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole reply as one string.
    public func complete(_ request: AIRequest) async throws -> String {
        var text = ""
        for try await delta in respond(to: request) { text += delta }
        return text
    }
}

public enum BackendError: LocalizedError, Equatable {
    case serverUnavailable(name: String, url: String, hint: String)
    case noModel(name: String, hint: String)
    case http(status: Int, body: String)
    case failed(String)
    case badResponse(String)
    case appleIntelligenceUnavailable(AppleIntelligenceUnavailability)
    /// The prompt doesn't fit in the model's context window.
    case contextTooLong
    /// The model declined to answer (content guardrails).
    case refused(name: String)
    /// The model gave the text back, or only part of it, instead of translating it all.
    case untranslated
    /// No complete answer within the time allowed.
    case timedOut(name: String, seconds: Int)
    /// The model got stuck saying the same thing over and over.
    case repeating(name: String)
    /// The reply reached its length limit (or the model's context) before it was finished.
    case cutOff(name: String)

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable(let name, let url, let hint):
            "\(name) isn't reachable at \(url). \(hint)"
        case .noModel(let name, let hint):
            "\(name) has no model available. \(hint)"
        case .http(let status, let body):
            "The AI server returned HTTP \(status): \(body.prefix(300))"
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
        case .timedOut(let name, let seconds):
            "\(name) didn't finish within \(seconds) seconds. If it thinks before answering, turn thinking down in the AI tab, or try a smaller model."
        case .repeating(let name):
            "\(name) got stuck repeating itself. Try again, or pick another model in the AI tab."
        case .cutOff(let name):
            "\(name) stopped before finishing: the reply ran far longer than expected or filled the model's context. Try again, or try a shorter text."
        }
    }
}
