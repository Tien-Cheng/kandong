import Foundation

/// A model in LM Studio's native model list (`GET /api/v0/models`).
public struct LMStudioModel: Hashable, Sendable, Identifiable {
    public let id: String
    /// "llm", "vlm" (can read images) or "embeddings".
    public let type: String
    /// "loaded" or "not-loaded".
    public let state: String

    public var canReadImages: Bool { type == "vlm" }
    public var isLoaded: Bool { state == "loaded" }
}

public enum LMStudio {
    public static let startHint = "Open LM Studio and start the local server (Developer tab, or `lms server start`)."

    /// Chat-capable models, loaded ones first.
    public static func models(baseURL: String) async throws -> [LMStudioModel] {
        guard let url = URL(string: rootURL(baseURL) + "/api/v0/models") else {
            throw BackendError.serverUnavailable(name: "LM Studio", url: baseURL, hint: "Check the server URL.")
        }
        let data: Data
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw BackendError.serverUnavailable(name: "LM Studio", url: baseURL, hint: startHint)
        }
        let json = try JSONValue.decode(data)
        let models = (json["data"]?.array ?? []).compactMap { item -> LMStudioModel? in
            guard let id = item["id"]?.string else { return nil }
            return LMStudioModel(id: id, type: item["type"]?.string ?? "llm", state: item["state"]?.string ?? "")
        }
        return models.filter { $0.type != "embeddings" }.sorted { $0.isLoaded && !$1.isLoaded }
    }

    /// "http://localhost:1234/v1" → "http://localhost:1234".
    static func rootURL(_ baseURL: String) -> String {
        var root = baseURL.trimmingCharacters(in: .whitespaces)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        return root
    }
}

/// Any server speaking OpenAI's `/chat/completions` API: LM Studio, Ollama, hosted APIs.
public struct OpenAICompatibleBackend: AIBackend {
    public let kind: BackendKind
    public let settings: OpenAISettings
    public let apiKey: String?

    public init(kind: BackendKind, settings: OpenAISettings, apiKey: String? = nil) {
        self.kind = kind
        self.settings = settings
        self.apiKey = apiKey
    }

    private var name: String { kind.displayName }

    public var label: String {
        settings.model.isEmpty ? name : "\(name) · \(settings.model)"
    }

    private var baseURL: String {
        var url = settings.baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    public func supportsImages() async -> Bool {
        switch settings.vision {
        case .yes: return true
        case .no: return false
        case .auto:
            guard kind == .lmStudio, let models = try? await LMStudio.models(baseURL: baseURL) else { return false }
            let model = try? await resolveModel(lmStudioModels: models)
            return models.first { $0.id == model }?.canReadImages ?? false
        }
    }

    /// The configured model, or the first one the server offers.
    func resolveModel(lmStudioModels: [LMStudioModel]? = nil) async throws -> String {
        if !settings.model.isEmpty { return settings.model }
        if kind == .lmStudio {
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

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await resolveModel()
                    var useSchema = request.schema != nil
                    while true {
                        let outcome = try await stream(request, model: model, useSchema: useSchema, continuation: continuation)
                        // Some servers reject `response_format`; retry once relying on the prompt alone.
                        if case .rejectedSchema = outcome, useSchema { useSchema = false; continue }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Outcome { case done, rejectedSchema }

    /// Servers word this differently: OpenAI "maximum context length", llama.cpp/LM Studio "n_ctx",
    /// "context length", Ollama "exceeds the context", others "too many tokens".
    static func isContextOverflow(status: Int, body: String) -> Bool {
        guard [400, 413, 422, 500].contains(status) else { return false }
        let text = body.lowercased()
        return ["context length", "context window", "maximum context", "n_ctx", "exceeds the context",
                "too many tokens", "context_length_exceeded", "prompt is too long"].contains { text.contains($0) }
    }

    private func stream(
        _ request: AIRequest, model: String, useSchema: Bool,
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
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "temperature": .number(0.2),
            "messages": [
                ["role": "system", "content": .string(request.system)],
                ["role": "user", "content": userContent],
            ],
        ]
        if useSchema, let schema = request.schema {
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
            let hint = kind == .lmStudio ? LMStudio.startHint : "Is the server running?"
            throw BackendError.serverUnavailable(name: name, url: baseURL, hint: hint)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            var text = ""
            for try await line in bytes.lines { text += line }
            if Self.isContextOverflow(status: status, body: text) { throw BackendError.contextTooLong }
            if useSchema, status == 400 || status == 422 { return .rejectedSchema }
            throw BackendError.http(status: status, body: text)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = try? JSONValue.decode(Data(payload.utf8)) else { continue }
            if let message = json["error"]?["message"]?.string {
                if Self.isContextOverflow(status: 400, body: message) { throw BackendError.contextTooLong }
                throw BackendError.failed(message)
            }
            if let delta = json["choices"]?.array?.first?["delta"]?["content"]?.string, !delta.isEmpty {
                continuation.yield(delta)
            }
        }
        return .done
    }
}
