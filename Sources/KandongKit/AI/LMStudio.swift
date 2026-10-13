import Foundation

/// A model downloaded in LM Studio.
public struct LMStudioModel: Hashable, Sendable, Identifiable {
    public let id: String
    /// "llm", "vlm" (can read images) or "embeddings".
    public let type: String
    /// "loaded" or "not-loaded".
    public let state: String
    /// The thinking levels it offers, least first, e.g. ["off", "on"]; empty when it doesn't think.
    public var reasoningOptions: [String] = []

    public var canReadImages: Bool { type == "vlm" }
    public var isLoaded: Bool { state == "loaded" }
    public var canThink: Bool { !reasoningOptions.isEmpty }
}

/// How far an LM Studio download has got.
public struct LMStudioDownload: Equatable, Sendable {
    public enum State: Equatable, Sendable { case downloading, paused, completed, failed(String) }
    public var state: State
    public var downloadedBytes: Int64
    public var totalBytes: Int64

    public var fraction: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }
}

public enum LMStudio {
    public static let bundleID = "ai.elementlabs.lmstudio"
    public static let website = URL(string: "https://lmstudio.ai")!
    public static let startHint = "Open LM Studio and start the local server (Developer tab, or `lms server start`)."

    /// Chat-capable models, loaded ones first.
    public static func models(baseURL: String) async throws -> [LMStudioModel] {
        let models: [LMStudioModel]
        do {
            models = try await modelsV1(baseURL: baseURL)
        } catch BackendError.http(let status, _) where status == 404 {
            // LM Studio before 0.4 only has the beta API.
            models = try await modelsV0(baseURL: baseURL)
        } catch BackendError.badResponse {
            models = try await modelsV0(baseURL: baseURL)
        }
        return models.filter { $0.type != "embeddings" }.sorted { $0.isLoaded && !$1.isLoaded }
    }

    /// `GET /api/v1/models`, which also says how each model can think.
    static func modelsV1(baseURL: String) async throws -> [LMStudioModel] {
        let json = try await get("/api/v1/models", baseURL: baseURL)
        guard let items = json["models"]?.array else { throw BackendError.badResponse("no model list") }
        return items.compactMap { item in
            guard let id = item["key"]?.string else { return nil }
            let vision = item["capabilities"]?["vision"]?.bool == true
            let type = switch item["type"]?.string ?? "llm" {
            case "embedding", "embeddings": "embeddings"
            case "llm": vision ? "vlm" : "llm"
            case let other: other
            }
            return LMStudioModel(
                id: id,
                type: type,
                state: (item["loaded_instances"]?.array?.isEmpty ?? true) ? "not-loaded" : "loaded",
                reasoningOptions: item["capabilities"]?["reasoning"]?["allowed_options"]?.array?.compactMap(\.string) ?? []
            )
        }
    }

    static func modelsV0(baseURL: String) async throws -> [LMStudioModel] {
        let json = try await get("/api/v0/models", baseURL: baseURL)
        return (json["data"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.string else { return nil }
            return LMStudioModel(id: id, type: item["type"]?.string ?? "llm", state: item["state"]?.string ?? "")
        }
    }

    /// Starts downloading a model, e.g. "google/gemma-4-e4b"; nil when it is already downloaded.
    public static func startDownload(_ model: String, baseURL: String) async throws -> String? {
        let json = try await post("/api/v1/models/download", ["model": .string(model)], baseURL: baseURL, timeout: 30)
        if json["status"]?.string == "already_downloaded" { return nil }
        guard let job = json["job_id"]?.string else { throw BackendError.badResponse("LM Studio didn't start the download") }
        return job
    }

    public static func download(_ job: String, baseURL: String) async throws -> LMStudioDownload {
        let json = try await get("/api/v1/models/download/status/\(job)", baseURL: baseURL)
        let state: LMStudioDownload.State = switch json["status"]?.string {
        case "completed": .completed
        case "paused": .paused
        case "failed": .failed(json["error"]?.string ?? json["error"]?["message"]?.string ?? "The download failed.")
        default: .downloading
        }
        return LMStudioDownload(
            state: state,
            downloadedBytes: Int64(json["downloaded_bytes"]?.number ?? 0),
            totalBytes: Int64(json["total_size_bytes"]?.number ?? 0)
        )
    }

    /// Loads a model into memory, so a model too big for this Mac fails here rather than mid-Lookup.
    public static func load(_ model: String, baseURL: String) async throws {
        _ = try await post("/api/v1/models/load", ["model": .string(model)], baseURL: baseURL, timeout: 300)
    }

    /// Whether LM Studio refused to load a model for lack of memory.
    public static func isOutOfMemory(_ error: Error) -> Bool {
        guard case BackendError.http(_, let body) = error else { return false }
        let text = body.lowercased()
        return ["insufficient", "not enough memory", "out of memory", "system resources", "guardrail"].contains { text.contains($0) }
    }

    /// Opens a model's page in LM Studio, for versions without the download API.
    public static func deepLink(huggingFaceRepo: String) -> URL? {
        var components = URLComponents()
        components.scheme = "lmstudio"
        components.host = "open_from_hf"
        components.queryItems = [URLQueryItem(name: "model", value: huggingFaceRepo)]
        return components.url
    }

    // MARK: HTTP

    private static func get(_ path: String, baseURL: String) async throws -> JSONValue {
        guard let url = URL(string: rootURL(baseURL) + path) else {
            throw BackendError.serverUnavailable(name: "LM Studio", url: baseURL, hint: "Check the server URL.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return try await send(request, baseURL: baseURL)
    }

    private static func post(_ path: String, _ body: [String: JSONValue], baseURL: String, timeout: TimeInterval) async throws -> JSONValue {
        guard let url = URL(string: rootURL(baseURL) + path) else {
            throw BackendError.serverUnavailable(name: "LM Studio", url: baseURL, hint: "Check the server URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object(body).encoded()
        return try await send(request, baseURL: baseURL)
    }

    private static func send(_ request: URLRequest, baseURL: String) async throws -> JSONValue {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BackendError.serverUnavailable(name: "LM Studio", url: baseURL, hint: startHint)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let json = try? JSONValue.decode(data)
        guard (200..<300).contains(status) else {
            let message = json?["error"]?["message"]?.string ?? json?["error"]?.string
            throw BackendError.http(status: status, body: message ?? String(decoding: data, as: UTF8.self))
        }
        guard let json else { throw BackendError.badResponse("LM Studio sent something that isn't JSON") }
        return json
    }

    /// "http://localhost:1234/v1" → "http://localhost:1234".
    static func rootURL(_ baseURL: String) -> String {
        var root = baseURL.trimmingCharacters(in: .whitespaces)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        return root
    }
}
