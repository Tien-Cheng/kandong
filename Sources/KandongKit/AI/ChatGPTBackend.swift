import Foundation

/// An account-specific model from the ChatGPT plan catalog, in server display order.
public struct ChatGPTModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let supportsImages: Bool

    public init(id: String, displayName: String, supportsImages: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.supportsImages = supportsImages
    }
}

/// Keeps account-specific admission failures across backend instances rebuilt by settings.
public actor ChatGPTBackendState {
    private var usageLimits: [String: String] = [:]
    private var revisions: [String: UInt64] = [:]
    public init() {}
    public func clear(accountID: String) {
        usageLimits[accountID] = nil
        revisions[accountID, default: 0] += 1
    }
    func usageLimit(accountID: String) -> String? { usageLimits[accountID] }
    func requestState(accountID: String) -> (message: String?, revision: UInt64) {
        (usageLimits[accountID], revisions[accountID, default: 0])
    }
    func clear(accountID: String, ifUnchanged revision: UInt64) {
        guard revisions[accountID, default: 0] == revision else { return }
        clear(accountID: accountID)
    }
    func recordUsageLimit(_ message: String, accountID: String) {
        usageLimits[accountID] = message
        revisions[accountID, default: 0] += 1
    }
}

/// Direct Responses inference paid for by the selected ChatGPT plan.
public struct ChatGPTBackend: AIBackend {
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    public let settings: ChatGPTSettings
    public let readingMode: ReadingMode
    private let urlSession: URLSession
    private let state: ChatGPTBackendState
    private let credentials: @Sendable () async throws -> (accountID: String, token: String, generation: UInt64?)
    private let validate: (@Sendable (String, UInt64) async throws -> Void)?
    private let register: (@Sendable (String, @escaping @Sendable () -> Void) async throws -> UUID)?
    private let unregister: (@Sendable (UUID) async -> Void)?
    /// Overrides the ordinary request deadline in transport tests.
    var timeLimit: Int?

    public init(settings: ChatGPTSettings, session: ChatGPTSession, readingMode: ReadingMode = .free, urlSession: URLSession = .shared, state: ChatGPTBackendState = ChatGPTBackendState()) {
        self.settings = settings
        self.readingMode = readingMode
        self.urlSession = urlSession
        self.state = state
        self.credentials = {
            let accounts = try await session.accounts()
            guard let accountID = settings.accountID,
                  let account = accounts.first(where: { $0.id == accountID }), account.isSignedIn else { throw ChatGPTError.signedOut }
            guard account.hasPlanPermission else { throw ChatGPTError.planPermissionMissing }
            let generation = try await session.requestGeneration(accountID: account.id)
            let token = try await session.accessToken(for: account.id)
            try await session.validateRequest(accountID: account.id, generation: generation)
            return (account.id, token, generation)
        }
        self.validate = { try await session.validateRequest(accountID: $0, generation: $1) }
        self.register = { accountID, cancel in try await session.registerRequest(accountID: accountID, cancel: cancel) }
        self.unregister = { await session.unregisterRequest($0) }
    }

    /// Tokens in tests never come from a user's saved account.
    init(settings: ChatGPTSettings, urlSession: URLSession, state: ChatGPTBackendState = ChatGPTBackendState(), tokenProvider: @escaping @Sendable () async throws -> String) {
        self.settings = settings
        self.readingMode = .free
        self.urlSession = urlSession
        self.state = state
        self.credentials = { ("test-account", try await tokenProvider(), nil) }
        self.validate = nil
        self.register = nil
        self.unregister = nil
    }

    public var label: String { settings.model.isEmpty ? "ChatGPT" : "ChatGPT · \(settings.model)" }

    public func status() async -> BackendStatus {
        do {
            let credential = try await credentials()
            if let message = await state.usageLimit(accountID: credential.accountID) {
                return .needsSetup(message, fix: .openURL(Self.usageURL, label: "Manage usage"))
            }
            let model = try resolveModel(in: await accountCatalog(credential))
            return .ready("Using ChatGPT plan · \(model.displayName)")
        } catch ChatGPTError.signedOut {
            return .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT)
        } catch ChatGPTError.planPermissionMissing {
            return .needsSetup("Enable ChatGPT plan usage to translate.", fix: .connectChatGPT)
        } catch ChatGPTError.usageLimit(let message) {
            return .needsSetup(message, fix: .openURL(Self.usageURL, label: "Manage usage"))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func models() async throws -> [ChatGPTModel] {
        let credential = try await credentials()
        return try await accountCatalog(credential)
    }

    private func accountCatalog(_ credential: (accountID: String, token: String, generation: UInt64?)) async throws -> [ChatGPTModel] {
        let cancellation = ChatGPTRequestCancellation()
        let registration = try await register?(credential.accountID, { cancellation.cancel() })
        defer { if let registration { Task { await unregister?(registration) } } }
        let operation = Task {
            try Task.checkCancellation()
            if let generation = credential.generation { try await validate?(credential.accountID, generation) }
            let models = try await catalog(token: credential.token)
            if let generation = credential.generation { try await validate?(credential.accountID, generation) }
            return models
        }
        cancellation.install(operation)
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { cancellation.cancel() }
    }

    private func catalog(token: String) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try checkHTTP(response, data: data, token: token)
        guard let models = try JSONValue.decode(data)["models"]?.array else {
            throw BackendError.badResponse("ChatGPT did not return its model catalog.")
        }
        return models.compactMap { model in
            guard model["visibility"]?.string == "list", let slug = model["slug"]?.string, !slug.isEmpty else { return nil }
            // Capability metadata is optional. Never infer vision from a model's name.
            let vision = model["supports_images"]?.bool
                ?? model["capabilities"]?["vision"]?.bool
                ?? model["input_modalities"]?.array?.contains(.string("image"))
                ?? false
            return ChatGPTModel(id: slug, displayName: model["display_name"]?.string ?? slug, supportsImages: vision)
        }
    }

    private func resolveModel(in catalog: [ChatGPTModel]) throws -> ChatGPTModel {
        guard let model = settings.model.isEmpty ? catalog.first : catalog.first(where: { $0.id == settings.model }) else {
            throw BackendError.noModel(name: "ChatGPT", hint: settings.model.isEmpty
                ? "Your account currently offers no models. Check your ChatGPT plan."
                : "Choose a model available to this ChatGPT account in AI settings.")
        }
        return model
    }

    public func supportsImages() async -> Bool {
        switch settings.vision {
        case .yes: return true
        case .no: return false
        case .auto: return (try? await resolveModel(in: models()).supportsImages) ?? false
        }
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let seconds = timeLimit ?? OpenAICompatibleBackend.deadline(for: request)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await answer(request, continuation: continuation) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(seconds))
                            throw BackendError.timedOut(name: label, seconds: seconds)
                        }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ request: AIRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let credential = try await credentials()
        let admission = await state.requestState(accountID: credential.accountID)
        if let message = admission.message { throw ChatGPTError.usageLimit(message) }
        let cancellation = ChatGPTRequestCancellation()
        let registration = try await register?(credential.accountID, { cancellation.cancel() })
        defer { if let registration { Task { await unregister?(registration) } } }
        let operation = Task {
            try Task.checkCancellation()
            if let generation = credential.generation { try await validate?(credential.accountID, generation) }
            let model = try resolveModel(in: await catalog(token: credential.token))
            if let generation = credential.generation { try await validate?(credential.accountID, generation) }
            try await stream(request, model: model.id, token: credential.token, continuation: continuation)
            if let generation = credential.generation { try await validate?(credential.accountID, generation) }
        }
        cancellation.install(operation)
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                cancellation.cancel()
            }
            await state.clear(accountID: credential.accountID, ifUnchanged: admission.revision)
        } catch ChatGPTError.usageLimit(let message) {
            await state.recordUsageLimit(message, accountID: credential.accountID)
            throw ChatGPTError.usageLimit(message)
        }
    }

    func body(for request: AIRequest, model: String) -> JSONValue {
        var content: [JSONValue] = [["type": "input_text", "text": .string(request.user)]]
        if let image = request.image {
            content.append(["type": "input_image", "image_url": .string("data:image/png;base64," + image.base64EncodedString())])
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(request.system),
            "input": [["role": "user", "content": .array(content)]],
            "store": false, "stream": true,
        ]
        if let schema = request.schema {
            body["text"] = ["format": ["type": "json_schema", "name": "result", "strict": true, "schema": schema]]
        }
        if let effort = Reasoning.effort(settings.reasoning[request.task]) { body["reasoning"] = ["effort": .string(effort)] }
        return .object(body)
    }

    private func stream(_ request: AIRequest, model: String, token: String, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try body(for: request, model: model).encoded()
        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse("ChatGPT returned no HTTP response.") }
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { if data.count < 65_536 { data.append(byte) } }
            try checkHTTP(response, data: data, token: token)
        }
        let who = "ChatGPT · \(model)"
        var parser = ChatGPTEventParser()
        var reply = "", thinking = "", checked = 0, thought = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try parser.append(byte) else { continue }
            guard event.data != "[DONE]" else { throw BackendError.cutOff(name: who) }
            guard let json = try? JSONValue.decode(Data(event.data.utf8)) else {
                throw BackendError.badResponse("ChatGPT sent an invalid stream event.")
            }
            let type = json["type"]?.string ?? event.type
            switch type {
            case "response.output_text.delta":
                guard let delta = json["delta"]?.string else { throw BackendError.badResponse("ChatGPT sent an invalid text delta.") }
                reply += delta
                if request.image == nil, reply.count - checked >= 64 {
                    checked = reply.count
                    if RepetitionDetector().isRepeating(reply, source: request.user) { throw BackendError.repeating(name: who) }
                }
                continuation.yield(delta)
            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                if !thought { thought = true; await request.onThinking?() }
                if let delta = json["delta"]?.string {
                    thinking = String((thinking + delta).suffix(1000))
                    if RepetitionDetector().isRepeating(thinking, source: request.user) { throw BackendError.repeating(name: who) }
                }
            case "response.refusal.delta", "response.refusal.done":
                throw BackendError.refused(name: who)
            case "response.failed", "error":
                throw responseError(json["response"]?["error"] ?? json["error"] ?? json,
                                    status: nil, requestID: http.value(forHTTPHeaderField: "x-request-id"), token: token)
            case "response.incomplete":
                throw BackendError.cutOff(name: who)
            case "response.completed":
                let result = json["response"]
                if let error = result?["error"], !error.isNull {
                    throw responseError(error, status: nil, requestID: http.value(forHTTPHeaderField: "x-request-id"), token: token)
                }
                if let status = result?["status"]?.string, status != "completed" { throw BackendError.cutOff(name: who) }
                if result?["output"]?.array?.contains(where: { item in
                    item["content"]?.array?.contains(where: { $0["type"]?.string == "refusal" }) ?? false
                }) == true { throw BackendError.refused(name: who) }
                guard !reply.isEmpty else { throw BackendError.badResponse("ChatGPT completed without an answer.") }
                return
            default: break
            }
        }
        throw BackendError.cutOff(name: who)
    }

    private func checkHTTP(_ response: URLResponse, data: Data, token: String) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse("ChatGPT returned no HTTP response.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let json = try? JSONValue.decode(data)
        let error = json?["error"] ?? json
        if OpenAICompatibleBackend.isContextOverflow(status: http.statusCode, body: String(decoding: data, as: UTF8.self)) {
            throw BackendError.contextTooLong
        }
        throw responseError(error ?? .string(String(decoding: data, as: UTF8.self)), status: http.statusCode,
                            requestID: http.value(forHTTPHeaderField: "x-request-id"), token: token,
                            body: String(decoding: data, as: UTF8.self))
    }

    private func responseError(_ error: JSONValue, status: Int?, requestID: String?, token: String, body: String? = nil) -> Error {
        let code = error["code"]?.string
        let message = error["message"]?.string ?? error["detail"]?.string ?? error.string ?? "ChatGPT could not complete this request."
        var diagnostic = message.replacingOccurrences(of: token, with: "[redacted]")
        if let code { diagnostic += " (\(code))" }
        if let param = error["param"]?.string { diagnostic += " Parameter: \(param)." }
        if let status { diagnostic += " HTTP \(status)." }
        if let requestID { diagnostic += " Request: \(requestID)." }
        diagnostic = diagnostic.replacingOccurrences(of: token, with: "[redacted]")
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return ChatGPTError.usageLimit(diagnostic)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return ChatGPTError.unavailable(diagnostic)
        default:
            if let status {
                // Retain admission body shape and status for diagnosing route/permission errors.
                let details = (body ?? diagnostic).replacingOccurrences(of: token, with: "[redacted]")
                let request = requestID.map { " Request: " + $0.replacingOccurrences(of: token, with: "[redacted]") + "." } ?? ""
                return BackendError.http(status: status, body: details + request)
            }
            return BackendError.failed(diagnostic)
        }
    }
}

/// Frames SSE across arbitrary byte fragments, including CRLF and multi-line data.
struct ChatGPTEventParser {
    struct Event { let type: String?; let data: String }
    private var line = Data()
    private var data: [String] = []
    private var type: String?
    private var eventSize = 0

    mutating func append(_ byte: UInt8) throws -> Event? {
        guard byte == 10 else {
            line.append(byte)
            guard line.count + eventSize <= 1_048_576 else { throw BackendError.badResponse("ChatGPT sent an oversized stream event.") }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            defer { data.removeAll(keepingCapacity: true); type = nil; eventSize = 0 }
            return data.isEmpty ? nil : Event(type: type, data: data.joined(separator: "\n"))
        }
        guard !value.hasPrefix(":"), let colon = value.firstIndex(of: ":") else { return nil }
        let field = value[..<colon]
        var text = String(value[value.index(after: colon)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        if field == "data" { data.append(text); eventSize += text.utf8.count }
        else if field == "event" { type = text }
        return nil
    }
}

private final class ChatGPTRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    private var cancelled = false

    func install<T: Sendable>(_ task: Task<T, Error>) {
        lock.lock()
        self.cancellation = { task.cancel() }
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = cancellation
        lock.unlock()
        current?()
    }
}
