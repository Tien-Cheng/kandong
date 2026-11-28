import Foundation

/// Thinking capabilities reported by Anthropic's `/v1/models` `capabilities.thinking.types` object.
public struct AnthropicThinkingCapabilities: Hashable, Sendable {
    public let supportsDisabled: Bool?
    public let supportsBetweenTools: Bool?
    public let supportsAdaptive: Bool?

    public init(supportsDisabled: Bool? = nil, supportsBetweenTools: Bool? = nil, supportsAdaptive: Bool? = nil) {
        self.supportsDisabled = supportsDisabled
        self.supportsBetweenTools = supportsBetweenTools
        self.supportsAdaptive = supportsAdaptive
    }

    /// Whether the model supports turning upfront thinking off (via `disabled` or `between_tools`).
    /// Nil capability metadata is treated optimistically until the API says otherwise.
    public var canDisableThinking: Bool {
        if supportsDisabled == true || supportsBetweenTools == true { return true }
        if supportsDisabled == false { return false }
        return true
    }
}

/// A model reported by Anthropic's `/v1/models` endpoint.
public struct AnthropicModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let supportsImages: Bool
    public let maxTokens: Int?
    public let thinking: AnthropicThinkingCapabilities

    public init(
        id: String,
        displayName: String,
        supportsImages: Bool = false,
        maxTokens: Int? = nil,
        thinking: AnthropicThinkingCapabilities = AnthropicThinkingCapabilities()
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsImages = supportsImages
        self.maxTokens = maxTokens
        self.thinking = thinking
    }

    /// Thinking options this model supports in UI order (always starting with Model default `""`).
    public var allowedThinkingLevels: [String] {
        if thinking.canDisableThinking {
            return [""] + Reasoning.anthropicLevels
        }
        return [""] + Reasoning.anthropicLevels.filter { $0 != "off" }
    }

    /// The effective thinking level used for a saved `wanted` setting on this model, matching
    /// `ThinkingPicker`'s fallback label (e.g., `"off"` resolves to `"low"` when thinking can't be turned off).
    public func resolvedThinkingLevel(for wanted: String) -> String {
        Reasoning.resolve(wanted, allowed: allowedThinkingLevels)
    }
}

/// Identifies the exact backend, URL, and API key a Claude `/v1/models` fetch belongs to.
public struct AnthropicModelFetchKey: Equatable, Sendable {
    public let backendID: String
    public let baseURL: String
    public let apiKey: String

    public init(backendID: String, baseURL: String, apiKey: String) {
        self.backendID = backendID
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// Coordinates Claude `/v1/models` fetches so stale or cancelled requests can never overwrite newer
/// models, errors, or loading state when credentials, URL, or backend selection change.
public struct AnthropicModelCatalogState: Equatable, Sendable {
    public private(set) var models: [AnthropicModel] = []
    public private(set) var error = ""
    public private(set) var isLoading = false
    public private(set) var activeKey: AnthropicModelFetchKey?
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Starts a fetch for `key` (or clears state when the key is empty). Returns the generation token to
    /// validate on completion, or `nil` when no network fetch should run.
    @discardableResult
    public mutating func beginFetch(for key: AnthropicModelFetchKey) -> UInt64? {
        generation &+= 1
        activeKey = key
        models = []
        error = ""
        guard !key.apiKey.isEmpty else {
            isLoading = false
            return nil
        }
        isLoading = true
        return generation
    }

    /// Invalidates any in-flight fetch (e.g., when switching backends, editing Server URL, or closing the view).
    public mutating func invalidate(clearResults: Bool = false) {
        generation &+= 1
        activeKey = nil
        isLoading = false
        if clearResults {
            models = []
            error = ""
        }
    }

    /// Publishes fetch results only if both `generation` and `key` still match the active configuration.
    @discardableResult
    public mutating func finish(
        generation: UInt64,
        key: AnthropicModelFetchKey,
        result: Result<[AnthropicModel], Error>
    ) -> Bool {
        guard self.generation == generation, self.activeKey == key else { return false }
        isLoading = false
        switch result {
        case .success(let fetched):
            models = fetched
            error = ""
        case .failure(let failure):
            models = []
            error = failure.localizedDescription
        }
        return true
    }
}

/// Native Claude Backend speaking Anthropic's Messages API (`POST /v1/messages`, `GET /v1/models`).
public struct AnthropicBackend: AIBackend {
    public static let consoleKeysURL = URL(string: "https://console.anthropic.com/settings/keys")!
    public static let apiVersion = "2023-06-01"
    private static let maxModelPages = 50

    public let config: BackendConfig
    public let settings: AnthropicSettings
    public let apiKey: String?
    private let urlSession: URLSession
    /// Overrides `deadline(for:)`, for tests.
    var timeLimit: Int?

    public init(config: BackendConfig, apiKey: String? = nil, urlSession: URLSession = .shared) {
        self.config = config
        self.settings = config.anthropic ?? AnthropicSettings()
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    private var name: String { config.name }
    public var readingMode: ReadingMode { config.readingMode }

    public var label: String {
        settings.model.isEmpty ? name : "\(name) · \(settings.model)"
    }

    /// Normalized origin without trailing `/` or `/v1`.
    var baseURL: String {
        var url = settings.baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/v1") { url.removeLast(3) }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    public func status() async -> BackendStatus {
        guard let apiKey, !apiKey.isEmpty else {
            return .needsSetup("Add your Anthropic API key.", fix: .openURL(Self.consoleKeysURL, label: "Get API Key"))
        }
        do {
            let catalog = try await models()
            let model = try resolveModel(in: catalog)
            return .ready(config.isOnDevice ? "On this Mac · \(model.displayName)" : model.displayName)
        } catch BackendError.http(let status, _) where status == 401 || status == 403 {
            return .needsSetup("\(name) rejected the API key.")
        } catch BackendError.noModel(_, let hint) {
            return .needsSetup(hint)
        } catch {
            return .needsSetup("\(name) isn't reachable at \(settings.baseURL).")
        }
    }

    /// Lists every page of models returned by `GET /v1/models` using cursor pagination (`after_id`).
    public func models() async throws -> [AnthropicModel] {
        guard let apiKey, !apiKey.isEmpty else {
            throw BackendError.failed("Add your Anthropic API key in AI settings.")
        }
        var collected: [AnthropicModel] = []
        var seenIDs: Set<String> = []
        var afterID: String?

        for _ in 0..<Self.maxModelPages {
            guard var components = URLComponents(string: baseURL + "/v1/models") else {
                throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
            }
            var queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { queryItems.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

            let data: Data, response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check your internet connection or server URL.")
            }
            try checkHTTP(response, data: data, key: apiKey)

            let payload = try JSONValue.decode(data)
            guard let list = payload["data"]?.array else {
                throw BackendError.badResponse("\(name) did not return its model list.")
            }
            var lastEntryID: String?
            for entry in list {
                guard let id = entry["id"]?.string, !id.isEmpty else { continue }
                lastEntryID = id
                guard seenIDs.insert(id).inserted else { continue }
                let displayName = entry["display_name"]?.string ?? id
                // Never infer vision from model names; rely on capability metadata when provided.
                let capabilities = entry["capabilities"]
                let vision = capabilities?["image_input"]?["supported"]?.bool ?? false
                let maxTokens = entry["max_tokens"]?.number.map(Int.init)
                let thinkingTypes = capabilities?["thinking"]?["types"]
                let thinking = AnthropicThinkingCapabilities(
                    supportsDisabled: thinkingTypes?["disabled"]?["supported"]?.bool,
                    supportsBetweenTools: thinkingTypes?["between_tools"]?["supported"]?.bool,
                    supportsAdaptive: thinkingTypes?["adaptive"]?["supported"]?.bool
                )
                collected.append(AnthropicModel(
                    id: id,
                    displayName: displayName,
                    supportsImages: vision,
                    maxTokens: maxTokens,
                    thinking: thinking
                ))
            }

            guard payload["has_more"]?.bool == true else { break }
            let nextCursor = payload["last_id"]?.string ?? lastEntryID
            guard let nextCursor, !nextCursor.isEmpty, nextCursor != afterID else { break }
            afterID = nextCursor
        }
        return collected
    }

    private func resolveModel(in catalog: [AnthropicModel]) throws -> AnthropicModel {
        guard let model = settings.model.isEmpty ? catalog.first : catalog.first(where: { $0.id == settings.model }) else {
            throw BackendError.noModel(
                name: name,
                hint: settings.model.isEmpty
                    ? "\(name) lists no models. Check your Anthropic account."
                    : "Choose a model available to this Anthropic account in AI settings."
            )
        }
        return model
    }

    public func supportsImages() async -> Bool {
        switch settings.vision {
        case .yes: return true
        case .no: return false
        case .auto:
            guard let catalog = try? await models(),
                  let model = try? resolveModel(in: catalog) else { return false }
            return model.supportsImages
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

    enum ThinkingMode: Equatable {
        case modelDefault
        case disabled
        /// Disables upfront thinking on models (like Claude Sonnet 5.5) that reject `disabled`.
        case betweenTools
        case adaptive(effort: String?)
    }

    struct Options: Equatable {
        var useSchema: Bool
        var thinkingMode: ThinkingMode
    }

    func initialOptions(for request: AIRequest, model: AnthropicModel? = nil) -> Options {
        let wanted = config.reasoning[request.task]
        let effective = model?.resolvedThinkingLevel(for: wanted)
            ?? Reasoning.resolve(wanted, allowed: [""] + Reasoning.anthropicLevels)
        let thinkingMode: ThinkingMode
        switch effective {
        case "", "on":
            thinkingMode = .modelDefault
        case "off":
            if let caps = model?.thinking, caps.supportsDisabled == false, caps.supportsBetweenTools == true {
                thinkingMode = .betweenTools
            } else {
                thinkingMode = .disabled
            }
        default:
            thinkingMode = .adaptive(effort: effective)
        }
        return Options(useSchema: request.schema != nil, thinkingMode: thinkingMode)
    }

    func body(for request: AIRequest, model: String, options: Options, modelMaxTokens: Int? = nil) -> JSONValue {
        let userContent: JSONValue
        if let image = request.image {
            userContent = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": .string(image.base64EncodedString()),
                    ],
                ],
                ["type": "text", "text": .string(request.user)],
            ]
        } else {
            userContent = .string(request.user)
        }

        // Thinking tokens count toward max_tokens on Anthropic, so leave ample headroom when thinking may run.
        let desiredMaxTokens: Int = switch options.thinkingMode {
        case .disabled, .betweenTools: max(2048, request.expectedReplyLength * 3 + 2048)
        case .modelDefault, .adaptive: max(16_384, request.expectedReplyLength * 4 + 4096)
        }
        let maxTokens = modelMaxTokens.map { min(desiredMaxTokens, $0) } ?? desiredMaxTokens

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": true,
            "messages": [["role": "user", "content": userContent]],
        ]
        if !request.system.isEmpty {
            body["system"] = .string(request.system)
        }

        var outputConfig: [String: JSONValue] = [:]
        switch options.thinkingMode {
        case .modelDefault:
            break
        case .disabled:
            body["thinking"] = ["type": "disabled"]
        case .betweenTools:
            body["thinking"] = ["type": "between_tools"]
        case .adaptive(let effort):
            body["thinking"] = ["type": "adaptive"]
            if let effort { outputConfig["effort"] = .string(effort) }
        }
        if options.useSchema, let schema = request.schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        if !outputConfig.isEmpty {
            body["output_config"] = .object(outputConfig)
        }
        return .object(body)
    }

    private enum Outcome { case done, rejected(status: Int, body: String, requestID: String?) }

    private func answer(_ request: AIRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw BackendError.failed("Add your Anthropic API key in AI settings.")
        }
        let resolved: AnthropicModel
        if settings.model.isEmpty {
            resolved = try resolveModel(in: await models())
        } else if let catalog = try? await models(), let found = catalog.first(where: { $0.id == settings.model }) {
            resolved = found
        } else {
            resolved = AnthropicModel(id: settings.model, displayName: settings.model)
        }

        var options = initialOptions(for: request, model: resolved)
        while true {
            guard case .rejected(let status, let rawBody, let requestID) = try await stream(
                request, model: resolved, options: options, apiKey: apiKey, continuation: continuation
            ) else { return }

            let lower = rawBody.lowercased()
            // Never retry `disabled` by omitting `thinking` (which enables default adaptive thinking at higher effort).
            // Try `between_tools` first (no upfront thinking); if that is also rejected, fall back to lowest adaptive effort ("low"),
            // matching `ThinkingPicker`'s `Off (uses Low)` fallback.
            if options.thinkingMode == .disabled, lower.contains("thinking") || lower.contains("disabled") {
                if resolved.thinking.supportsBetweenTools != false {
                    options.thinkingMode = .betweenTools
                } else {
                    options.thinkingMode = .adaptive(effort: "low")
                }
            } else if options.thinkingMode == .betweenTools, lower.contains("thinking") || lower.contains("between_tools") {
                options.thinkingMode = .adaptive(effort: "low")
            } else if case .adaptive(let effort) = options.thinkingMode, effort != nil,
                      lower.contains("effort"), !lower.contains("thinking") {
                options.thinkingMode = .adaptive(effort: nil)
            } else if case .adaptive = options.thinkingMode,
                      lower.contains("thinking") || lower.contains("effort") {
                options.thinkingMode = .modelDefault
            } else if options.useSchema,
                      lower.contains("output_config") || lower.contains("json_schema") || lower.contains("format") {
                options.useSchema = false
            } else if options.useSchema {
                options.useSchema = false
            } else {
                throw errorFromBody(rawBody, status: status, requestID: requestID, key: apiKey)
            }
        }
    }

    private func stream(
        _ request: AIRequest,
        model: AnthropicModel,
        options: Options,
        apiKey: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> Outcome {
        guard let url = URL(string: baseURL + "/v1/messages") else {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check the server URL in Settings.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try body(for: request, model: model.id, options: options, modelMaxTokens: model.maxTokens).encoded()

        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: urlRequest)
        } catch {
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: "Check your internet connection or server URL.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.badResponse("\(name) returned no HTTP response.")
        }
        let requestID = http.value(forHTTPHeaderField: "request-id") ?? http.value(forHTTPHeaderField: "x-request-id")
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { if data.count < 65_536 { data.append(byte) } }
            let raw = String(decoding: data, as: UTF8.self)
            if OpenAICompatibleBackend.isContextOverflow(status: http.statusCode, body: raw) {
                throw BackendError.contextTooLong
            }
            if http.statusCode == 400 || http.statusCode == 422 {
                return .rejected(status: http.statusCode, body: raw, requestID: requestID)
            }
            throw errorFromBody(raw, status: http.statusCode, requestID: requestID, key: apiKey)
        }

        let who = "\(name) · \(model.id)"
        var parser = SSEEventParser(providerName: name)
        let detector = RepetitionDetector()
        var reply = "", thinking = "", checked = 0, thought = false
        var stopReason: String?

        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try parser.append(byte) else { continue }
            guard let json = try? JSONValue.decode(Data(event.data.utf8)) else {
                throw BackendError.badResponse("\(name) sent an invalid stream event.")
            }
            let type = json["type"]?.string ?? event.type
            switch type {
            case "content_block_start":
                if json["content_block"]?["type"]?.string == "thinking", !thought {
                    thought = true
                    await request.onThinking?()
                }
            case "content_block_delta":
                let delta = json["delta"]
                switch delta?["type"]?.string {
                case "text_delta":
                    guard let text = delta?["text"]?.string else {
                        throw BackendError.badResponse("\(name) sent an invalid text delta.")
                    }
                    reply += text
                    if request.image == nil, reply.count - checked >= 64 {
                        checked = reply.count
                        if detector.isRepeating(reply, source: request.user) {
                            throw BackendError.repeating(name: who)
                        }
                    }
                    continuation.yield(text)
                case "thinking_delta":
                    if !thought { thought = true; await request.onThinking?() }
                    if let text = delta?["thinking"]?.string {
                        thinking = String((thinking + text).suffix(1000))
                        if detector.isRepeating(thinking, source: request.user) {
                            throw BackendError.repeating(name: who)
                        }
                    }
                default:
                    break
                }
            case "message_delta":
                if let reason = json["delta"]?["stop_reason"]?.string {
                    stopReason = reason
                    if reason == "refusal" { throw BackendError.refused(name: who) }
                    if reason == "model_context_window_exceeded" { throw BackendError.contextTooLong }
                }
            case "error":
                let errorObj = json["error"] ?? json
                let message = errorObj["message"]?.string ?? "\(name) returned a stream error."
                if OpenAICompatibleBackend.isContextOverflow(status: 400, body: message) {
                    throw BackendError.contextTooLong
                }
                throw BackendError.failed(formatMessage(message, type: errorObj["type"]?.string, requestID: requestID, key: apiKey))
            case "message_stop":
                if stopReason == "refusal" { throw BackendError.refused(name: who) }
                if stopReason == "model_context_window_exceeded" { throw BackendError.contextTooLong }
                if stopReason == "max_tokens" { throw BackendError.cutOff(name: who) }
                guard !reply.isEmpty else {
                    throw BackendError.badResponse("\(name) completed without an answer.")
                }
                return .done
            default:
                break
            }
        }
        throw BackendError.cutOff(name: who)
    }

    private func checkHTTP(_ response: URLResponse, data: Data, key: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.badResponse("\(name) returned no HTTP response.")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let raw = String(decoding: data, as: UTF8.self)
        if OpenAICompatibleBackend.isContextOverflow(status: http.statusCode, body: raw) {
            throw BackendError.contextTooLong
        }
        let requestID = http.value(forHTTPHeaderField: "request-id") ?? http.value(forHTTPHeaderField: "x-request-id")
        throw errorFromBody(raw, status: http.statusCode, requestID: requestID, key: key)
    }

    private func errorFromBody(_ raw: String, status: Int, requestID: String?, key: String) -> Error {
        if let json = try? JSONValue.decode(Data(raw.utf8)), let error = json["error"] {
            let message = error["message"]?.string ?? raw
            let formatted = formatMessage(message, type: error["type"]?.string, requestID: requestID, key: key)
            return BackendError.http(status: status, body: formatted)
        }
        let redacted = raw.replacingOccurrences(of: key, with: "[redacted]")
        let req = requestID.map { " Request: \($0)." } ?? ""
        return BackendError.http(status: status, body: redacted + req)
    }

    private func formatMessage(_ message: String, type: String?, requestID: String?, key: String) -> String {
        var text = message.replacingOccurrences(of: key, with: "[redacted]")
        if let type, !type.isEmpty { text += " (\(type))" }
        if let requestID, !requestID.isEmpty { text += " Request: \(requestID)." }
        return text.replacingOccurrences(of: key, with: "[redacted]")
    }
}
