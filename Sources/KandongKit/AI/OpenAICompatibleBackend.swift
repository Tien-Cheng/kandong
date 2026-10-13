import Foundation

/// Any server speaking OpenAI's `/chat/completions` API: LM Studio, Ollama, hosted APIs.
public struct OpenAICompatibleBackend: AIBackend {
    public let config: BackendConfig
    public let settings: OpenAISettings
    public let apiKey: String?
    /// Overrides `deadline(for:)`, for tests.
    var timeLimit: Int?

    public init(config: BackendConfig, apiKey: String? = nil) {
        self.config = config
        self.settings = config.openAI ?? OpenAISettings(baseURL: (config.preset ?? .other).baseURL)
        self.apiKey = apiKey
    }

    private var name: String { config.name }
    private var isLMStudio: Bool { config.isLMStudio }

    public var label: String {
        settings.model.isEmpty ? name : "\(name) · \(settings.model)"
    }

    private var baseURL: String {
        var url = settings.baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    public func status() async -> BackendStatus {
        if config.preset?.needsKey == true, apiKey?.isEmpty ?? true {
            return .needsSetup("Add your \(config.preset?.displayName ?? name) API key.")
        }
        // Ask the server even when a model is configured, so a stopped server or a bad key shows up.
        do {
            let models = try await availableModels()
            guard let model = settings.model.isEmpty ? models.first : settings.model else {
                return .needsSetup(isLMStudio ? "LM Studio has no models yet. Download one in LM Studio." : "\(name) lists no models. Set a model name.")
            }
            return .ready(config.isOnDevice ? "On this Mac · \(model)" : model)
        } catch BackendError.http(let status, _) where status == 401 || status == 403 {
            return .needsSetup("\(name) rejected the API key.")
        } catch {
            if isLMStudio {
                return .needsSetup("LM Studio's server isn't running.", fix: .openApp(bundleID: LMStudio.bundleID, label: "Open LM Studio"))
            }
            return .needsSetup("\(name) isn't reachable at \(settings.baseURL).")
        }
    }

    /// The model ids the server offers (LM Studio: chat models, loaded ones first).
    func availableModels() async throws -> [String] {
        if isLMStudio { return try await LMStudio.models(baseURL: baseURL).map(\.id) }
        guard let url = URL(string: baseURL + "/models") else {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw BackendError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONValue.decode(data))?["data"]?.array?.compactMap { $0["id"]?.string } ?? []
    }

    public func supportsImages() async -> Bool {
        switch settings.vision {
        case .yes: return true
        case .no: return false
        case .auto:
            guard isLMStudio, let models = try? await LMStudio.models(baseURL: baseURL) else { return false }
            let model = try? await resolveModel(lmStudioModels: models)
            return models.first { $0.id == model }?.canReadImages ?? false
        }
    }

    /// The configured model, or the first one the server offers.
    func resolveModel(lmStudioModels: [LMStudioModel]? = nil) async throws -> String {
        if !settings.model.isEmpty { return settings.model }
        if isLMStudio {
            let models: [LMStudioModel]
            if let lmStudioModels { models = lmStudioModels } else { models = try await LMStudio.models(baseURL: baseURL) }
            guard let first = models.first else {
                throw BackendError.noModel(name: name, hint: "Download a model in LM Studio, e.g. Qwen3 or Gemma 3.")
            }
            return first.id
        }
        guard let url = URL(string: baseURL + "/models") else {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Is the server running?")
        }
        guard let id = (try? JSONValue.decode(data))?["data"]?.array?.first?["id"]?.string else {
            throw BackendError.noModel(name: name, hint: "Set a model name in Settings.")
        }
        return id
    }

    /// Small local models turn right readings wrong about as often as they fix one (see `KandongEval`),
    /// so for Backends on this Mac the dictionary's readings stand.
    public var correctsReadings: Bool { !config.isOnDevice }

    /// Seconds a request may take in all. Thinking models can reason for minutes and a stuck one never
    /// stops, so this is a hard limit, with more time for longer texts.
    static func deadline(for request: AIRequest) -> Int {
        (request.task == .explain ? 180 : 90) + request.expectedReplyLength / 20
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let seconds = timeLimit ?? Self.deadline(for: request)
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

    /// What one request asks of the server beyond the prompt.
    struct Options: Equatable {
        var useSchema: Bool
        /// `reasoning_effort`, or nil to leave it to the model.
        var effort: String?
        /// Whether the model will think: false when it can't or is told not to, nil when unknown.
        var thinks: Bool?

        /// A cap on the reply when the model won't think: far more than any answer needs, so only a
        /// rambling model reaches it. Thinking counts towards the cap, so a thinking model gets none.
        func maxTokens(for request: AIRequest) -> Int? {
            thinks == false ? request.expectedReplyLength * 3 + 2048 : nil
        }
    }

    /// The thinking level for this request's task, fitted to what an LM Studio model offers.
    func options(for request: AIRequest, model: String, lmStudioModels: [LMStudioModel]?) -> Options {
        let wanted = config.reasoning[request.task]
        var options = Options(useSchema: request.schema != nil, effort: Reasoning.effort(wanted), thinks: wanted == "off" ? false : nil)
        if let info = lmStudioModels?.first(where: { $0.id == model }) {
            guard info.canThink else { return Options(useSchema: options.useSchema, effort: nil, thinks: false) }
            let level = Reasoning.resolve(wanted, allowed: info.reasoningOptions)
            options.effort = Reasoning.effort(level)
            options.thinks = level != "off"
        }
        return options
    }

    private func answer(_ request: AIRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let lmStudioModels = isLMStudio ? try? await LMStudio.models(baseURL: baseURL) : nil
        let model = try await resolveModel(lmStudioModels: lmStudioModels)
        var options = options(for: request, model: model, lmStudioModels: lmStudioModels)
        while true {
            guard case .rejected(let status, let body) = try await stream(request, model: model, options: options, continuation: continuation) else { return }
            // Some servers reject `reasoning_effort` or `response_format`; retry without what they named.
            if options.effort != nil, body.lowercased().contains("reasoning") {
                options.effort = nil
                options.thinks = options.thinks == false ? nil : options.thinks
            } else if options.useSchema {
                options.useSchema = false
            } else {
                throw BackendError.http(status: status, body: body)
            }
        }
    }

    private enum Outcome { case done, rejected(status: Int, body: String) }

    /// Servers word this differently: OpenAI "maximum context length" / context_length_exceeded,
    /// llama.cpp "exceeds the available context size", LM Studio "context length of only N tokens".
    static func isContextOverflow(status: Int, body: String) -> Bool {
        guard [400, 413, 422, 500].contains(status) else { return false }
        let text = body.lowercased()
        return ["maximum context length", "context_length_exceeded", "exceeds the available context", "context length of only",
                "exceeds the context window", "too many tokens", "prompt is too long"].contains { text.contains($0) }
    }

    private func stream(
        _ request: AIRequest, model: String, options: Options,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> Outcome {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
        }
        var userContent: JSONValue = .string(request.user)
        if let image = request.image {
            userContent = [
                ["type": "text", "text": .string(request.user)],
                ["type": "image_url", "image_url": ["url": .string("data:image/png;base64," + image.base64EncodedString())]],
            ]
        }
        // No temperature or other sampling settings: LM Studio and Ollama apply each model's own
        // recommended ones, and overriding them (e.g. a low temperature on Qwen) makes models loop.
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "messages": [
                ["role": "system", "content": .string(request.system)],
                ["role": "user", "content": userContent],
            ],
        ]
        if let effort = options.effort { body["reasoning_effort"] = .string(effort) }
        if let maxTokens = options.maxTokens(for: request) { body["max_tokens"] = .number(Double(maxTokens)) }
        if options.useSchema, let schema = request.schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "result", "strict": true, "schema": schema],
            ]
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONValue.object(body).encoded()

        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            let hint = isLMStudio ? LMStudio.startHint : "Is the server running?"
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: hint)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            var text = ""
            for try await line in bytes.lines { text += line }
            if Self.isContextOverflow(status: status, body: text) { throw BackendError.contextTooLong }
            if status == 400 || status == 422 { return .rejected(status: status, body: text) }
            throw BackendError.http(status: status, body: text)
        }
        let who = "\(name) · \(model)"
        let detector = RepetitionDetector()
        var reply = "", thinking = "", replyLength = 0, checked = 0, thought = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = try? JSONValue.decode(Data(payload.utf8)) else { continue }
            if let message = json["error"]?["message"]?.string {
                if Self.isContextOverflow(status: 400, body: message) { throw BackendError.contextTooLong }
                throw BackendError.failed(message)
            }
            let choice = json["choices"]?.array?.first
            let delta = choice?["delta"]
            // LM Studio streams thinking as `reasoning_content`, OpenRouter and Ollama as `reasoning`.
            if let reasoning = delta?["reasoning_content"]?.string ?? delta?["reasoning"]?.string, !reasoning.isEmpty {
                if !thought { thought = true; await request.onThinking?() }
                thinking = String((thinking + reasoning).suffix(1000))
                if detector.isRepeating(thinking) { throw BackendError.repeating(name: who) }
            }
            if let content = delta?["content"]?.string, !content.isEmpty {
                continuation.yield(content)
                reply += content
                replyLength += content.count
                if replyLength - checked >= 64 {
                    checked = replyLength
                    if detector.isRepeating(reply) { throw BackendError.repeating(name: who) }
                }
            }
            if choice?["finish_reason"]?.string == "length", options.maxTokens(for: request) != nil {
                throw BackendError.repeating(name: who)
            }
        }
        return .done
    }
}
