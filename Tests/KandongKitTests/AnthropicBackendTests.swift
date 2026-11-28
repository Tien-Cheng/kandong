import Foundation
import Testing
@testable import KandongKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct AnthropicBackendTests {
    private static let catalog = #"""
    {
      "data": [
        {
          "type": "model",
          "id": "claude-sonnet-4-5",
          "display_name": "Claude Sonnet 4.5",
          "max_tokens": 64000,
          "capabilities": { "image_input": { "supported": true } }
        },
        {
          "type": "model",
          "id": "claude-text-only",
          "display_name": "Claude Text Only",
          "max_tokens": 8192,
          "capabilities": { "image_input": { "supported": false } }
        }
      ]
    }
    """#

    private func backend(
        model: String = "",
        apiKey: String? = "sk-ant-test-secret",
        vision: VisionSupport = .auto,
        reasoning: ReasoningSettings = .modelDefault,
        baseURL: String = AnthropicSettings.defaultBaseURL
    ) -> AnthropicBackend {
        var config = BackendConfig.anthropic(id: "claude-test")
        config.anthropic = AnthropicSettings(baseURL: baseURL)
        config.anthropic?.model = model
        config.anthropic?.vision = vision
        config.anthropic?.reasoning = reasoning
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AnthropicStubProtocol.self]
        return AnthropicBackend(config: config, apiKey: apiKey, urlSession: URLSession(configuration: sessionConfig))
    }

    private static func event(_ type: String, _ fields: [String: JSONValue] = [:]) throws -> String {
        var json = fields
        json["type"] = .string(type)
        return "event: \(type)\ndata: " + String(decoding: try JSONValue.object(json).encoded(), as: UTF8.self) + "\n\n"
    }

    private static func success(_ text: String = "Hello") throws -> String {
        try event("message_start", ["message": ["id": "msg_1"]])
            + event("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]])
            + event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": .string(text)]])
            + event("content_block_stop", ["index": 0])
            + event("message_delta", ["delta": ["stop_reason": "end_turn"]])
            + event("message_stop")
    }

    private static func stub(_ sse: String, status: Int = 200) {
        AnthropicStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            return (status, sse, status == 200 ? "text/event-stream" : "application/json")
        }
    }

    @Test func statusChecksMissingKeyRejectedKeyAndReadyState() async throws {
        AnthropicStubProtocol.setHandler { _ in (200, Self.catalog, "application/json") }
        let noKey = backend(apiKey: nil)
        let missing = await noKey.status()
        #expect(!missing.isReady)
        #expect(missing.fix == .openURL(AnthropicBackend.consoleKeysURL, label: "Get API Key"))
        #expect(AnthropicStubProtocol.requests().isEmpty)

        AnthropicStubProtocol.setHandler { _ in (401, #"{"error":{"type":"authentication_error","message":"Invalid x-api-key"}}"#, "application/json") }
        let rejected = await backend().status()
        #expect(!rejected.isReady)
        #expect(rejected.message.contains("rejected"))

        Self.stub(try Self.success())
        #expect(await backend().status() == .ready("Claude Sonnet 4.5"))
        #expect(await backend(model: "missing-model").status().isReady == false)
    }

    @Test func discoversModelsChecksVisionAndNormalizesBaseURL() async throws {
        Self.stub(try Self.success())
        let b = backend(baseURL: "https://api.anthropic.com/v1/")
        #expect(b.baseURL == "https://api.anthropic.com")
        let models = try await b.models()
        #expect(models.map(\.id) == ["claude-sonnet-4-5", "claude-text-only"])
        #expect(models.map(\.displayName) == ["Claude Sonnet 4.5", "Claude Text Only"])
        #expect(models[0].supportsImages && !models[1].supportsImages)
        #expect(await b.supportsImages())
        #expect(!(await backend(model: "claude-text-only").supportsImages()))
        #expect(await backend(model: "claude-text-only", vision: .yes).supportsImages())
        #expect(!(await backend(vision: .no).supportsImages()))
    }

    @Test func mapsStructuredPromptsImagesAndAdaptiveThinkingToMessagesAPI() async throws {
        Self.stub(try Self.success(#"{"translation":"Good morning"}"#))
        let b = backend(reasoning: ReasoningSettings(translate: "off", explain: "high"))
        let request = AIRequest(system: "Translate this image", user: "早上好", image: Data([1, 2, 3]), schema: Prompts.translationSchema)
        _ = try await b.complete(request)

        let sent = try #require(AnthropicStubProtocol.requests().last { $0.url?.path == "/v1/messages" })
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-secret")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == AnthropicBackend.apiVersion)

        let body = try JSONValue.decode(try #require(sent.httpBody))
        #expect(body["model"]?.string == "claude-sonnet-4-5")
        #expect(body["system"]?.string == "Translate this image")
        #expect(body["stream"]?.bool == true)
        #expect(body["thinking"]?["type"]?.string == "disabled")
        #expect(body["output_config"]?["effort"] == nil)
        #expect(body["output_config"]?["format"]?["type"]?.string == "json_schema")
        #expect(body["output_config"]?["format"]?["schema"] == Prompts.translationSchema)

        let content = try #require(body["messages"]?.array?.first?["content"]?.array)
        #expect(content[0]["type"]?.string == "image")
        #expect(content[0]["source"]?["type"]?.string == "base64")
        #expect(content[0]["source"]?["media_type"]?.string == "image/png")
        #expect(content[0]["source"]?["data"]?.string == "AQID")
        #expect(content[1]["type"]?.string == "text")
        #expect(content[1]["text"]?.string == "早上好")

        let explainReq = AIRequest(system: "Explain", user: "你好", task: .explain)
        let explainBody = b.body(for: explainReq, model: "claude-sonnet-4-5", options: try b.initialOptions(for: explainReq))
        #expect(explainBody["thinking"]?["type"]?.string == "adaptive")
        #expect(explainBody["output_config"]?["effort"]?.string == "high")
        #expect(explainBody["output_config"]?["format"] == nil)

        let defaultBackend = backend()
        let defaultBody = defaultBackend.body(for: explainReq, model: "claude-sonnet-4-5", options: try defaultBackend.initialOptions(for: explainReq))
        #expect(defaultBody["thinking"] == nil)
        #expect(defaultBody["output_config"] == nil)
    }

    @Test func offThinkingUsesBetweenToolsWhenDisabledRejectedAndNeverSilentlyEnablesAdaptive() async throws {
        // 1. Model advertising disabled=false, between_tools=true (e.g. Claude Sonnet 5.5) uses between_tools immediately.
        let sonnet55Catalog = #"""
        {
          "data": [{
            "type": "model",
            "id": "claude-sonnet-5-5",
            "display_name": "Claude Sonnet 5.5",
            "capabilities": {
              "image_input": { "supported": true },
              "thinking": {
                "types": {
                  "adaptive": { "supported": true },
                  "disabled": { "supported": false },
                  "between_tools": { "supported": true }
                }
              }
            }
          }]
        }
        """#
        let successSSE = try Self.success(#"{"translation":"Hi"}"#)
        AnthropicStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, sonnet55Catalog, "application/json") }
            return (200, successSSE, "text/event-stream")
        }
        let sonnet55 = backend(model: "claude-sonnet-5-5", reasoning: ReasoningSettings(translate: "off", explain: ""))
        #expect(try await sonnet55.complete(AIRequest(system: "Translate", user: "你好")) == #"{"translation":"Hi"}"#)
        let firstMsg = try #require(AnthropicStubProtocol.requests().last { $0.url?.path == "/v1/messages" })
        let firstBody = try JSONValue.decode(try #require(firstMsg.httpBody))
        #expect(firstBody["thinking"]?["type"]?.string == "between_tools")

        // 2. Model without thinking metadata rejecting `disabled` retries with `between_tools` (and if schema fails, drops schema).
        let attempts = AnthropicCounter()
        AnthropicStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            let n = attempts.next()
            if n == 1 {
                return (400, #"{"error":{"type":"invalid_request_error","message":"thinking.type disabled is not supported for this model"}}"#, "application/json")
            }
            if n == 2 {
                return (400, #"{"error":{"type":"invalid_request_error","message":"output_config.format is not supported"}}"#, "application/json")
            }
            return (200, successSSE, "text/event-stream")
        }
        let fallback = backend(reasoning: ReasoningSettings(translate: "off", explain: ""))
        #expect(try await fallback.complete(AIRequest(system: "Translate", user: "你好", schema: Prompts.translationSchema)) == #"{"translation":"Hi"}"#)
        let msgRequests = AnthropicStubProtocol.requests().filter { $0.url?.path == "/v1/messages" }
        #expect(msgRequests.count == 3)
        let thirdBody = try JSONValue.decode(try #require(msgRequests[2].httpBody))
        #expect(thirdBody["thinking"]?["type"]?.string == "between_tools")
        #expect(thirdBody["output_config"] == nil)

        // 3. Model rejecting BOTH `disabled` and `between_tools` fails cleanly rather than omitting `thinking` and enabling adaptive thinking.
        let alwaysOnAttempts = AnthropicCounter()
        AnthropicStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            _ = alwaysOnAttempts.next()
            return (400, #"{"error":{"type":"invalid_request_error","message":"thinking mode is not supported"}}"#, "application/json")
        }
        let alwaysOn = backend(reasoning: ReasoningSettings(translate: "off", explain: ""))
        await #expect(throws: BackendError.self) {
            _ = try await alwaysOn.complete(AIRequest(system: "Translate", user: "你好"))
        }
        let sentToAlwaysOn = AnthropicStubProtocol.requests().filter { $0.url?.path == "/v1/messages" }
        #expect(sentToAlwaysOn.count == 2)
        for req in sentToAlwaysOn {
            let body = try JSONValue.decode(try #require(req.httpBody))
            #expect(body["thinking"] != nil, "Off setting must never omit thinking and silently enable adaptive thinking")
        }

        // 4. Model advertising disabled=false and between_tools=false fails before sending /v1/messages.
        let noOffCatalog = #"""
        {
          "data": [{
            "type": "model",
            "id": "claude-always-thinking",
            "display_name": "Claude Always Thinking",
            "capabilities": {
              "thinking": {
                "types": {
                  "adaptive": { "supported": true },
                  "disabled": { "supported": false },
                  "between_tools": { "supported": false }
                }
              }
            }
          }]
        }
        """#
        AnthropicStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, noOffCatalog, "application/json") }
            return (200, successSSE, "text/event-stream")
        }
        let noOff = backend(model: "claude-always-thinking", reasoning: ReasoningSettings(translate: "off", explain: ""))
        await #expect(throws: BackendError.self) {
            _ = try await noOff.complete(AIRequest(system: "Translate", user: "你好"))
        }
        #expect(AnthropicStubProtocol.requests().allSatisfy { $0.url?.path == "/v1/models" })
    }

    @Test func paginatesAllModelPagesForDiscoveryStatusAndVision() async throws {
        let page1 = #"""
        {
          "data": [
            { "type": "model", "id": "claude-page-1", "display_name": "Claude Page 1", "capabilities": { "image_input": { "supported": false } } }
          ],
          "has_more": true,
          "first_id": "claude-page-1",
          "last_id": "claude-page-1"
        }
        """#
        let page2 = #"""
        {
          "data": [
            { "type": "model", "id": "claude-page-2", "display_name": "Claude Page 2", "capabilities": { "image_input": { "supported": true } } }
          ],
          "has_more": false,
          "first_id": "claude-page-2",
          "last_id": "claude-page-2"
        }
        """#
        AnthropicStubProtocol.setHandler { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let afterID = items.first(where: { $0.name == "after_id" })?.value
            if afterID == "claude-page-1" {
                return (200, page2, "application/json")
            }
            return (200, page1, "application/json")
        }

        let b = backend(model: "claude-page-2")
        let all = try await b.models()
        #expect(all.map(\.id) == ["claude-page-1", "claude-page-2"])
        #expect(await b.status() == .ready("Claude Page 2"))
        #expect(await b.supportsImages())
    }

    @Test func mapsModelContextWindowExceededStopReasonToContextTooLong() async throws {
        Self.stub(try Self.event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": "partial translation"]])
            + Self.event("message_delta", ["delta": ["stop_reason": "model_context_window_exceeded"]])
            + Self.event("message_stop"))
        await #expect(throws: BackendError.contextTooLong) {
            _ = try await backend().complete(AIRequest(system: "Translate", user: "很长的文本"))
        }
    }

    @Test func handlesFragmentedCRLFThinkingRefusalMaxTokensErrorsAndRedaction() async throws {
        let flag = AnthropicThinkingFlag()
        let sse = try Self.event("content_block_start", ["index": 0, "content_block": ["type": "thinking", "thinking": ""]])
            + Self.event("content_block_delta", ["index": 0, "delta": ["type": "thinking_delta", "thinking": "Step 1"]])
            + "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\r\ndata: \"delta\":{\"type\":\"text_delta\",\"text\":\"你好 🌞\"}}\r\n\r\n"
            + Self.event("message_delta", ["delta": ["stop_reason": "end_turn"]])
            + Self.event("message_stop")
        Self.stub(sse)
        var req = AIRequest(system: "", user: "Hi")
        req.onThinking = { await flag.increment() }
        #expect(try await backend().complete(req) == "你好 🌞")
        #expect(await flag.count == 1)

        // Refusal stop_reason
        Self.stub(try Self.event("message_delta", ["delta": ["stop_reason": "refusal"]]) + Self.event("message_stop"))
        await #expect(throws: BackendError.refused(name: "Claude · claude-sonnet-4-5")) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }

        // max_tokens cutOff
        Self.stub(try Self.event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": "partial"]])
            + Self.event("message_delta", ["delta": ["stop_reason": "max_tokens"]])
            + Self.event("message_stop"))
        await #expect(throws: BackendError.cutOff(name: "Claude · claude-sonnet-4-5")) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }

        // Premature EOF without message_stop
        Self.stub(try Self.event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": "partial"]]))
        await #expect(throws: BackendError.cutOff(name: "Claude · claude-sonnet-4-5")) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }

        // Context overflow maps to BackendError.contextTooLong
        Self.stub(#"{"error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#, status: 400)
        await #expect(throws: BackendError.contextTooLong) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }

        // Error redacts API key
        Self.stub(#"{"error":{"type":"authentication_error","message":"Bad key sk-ant-test-secret"}}"#, status: 401)
        do {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
            Issue.record("Expected HTTP 401 error")
        } catch BackendError.http(let status, let body) {
            #expect(status == 401)
            #expect(!body.contains("sk-ant-test-secret"))
            #expect(body.contains("[redacted]"))
            #expect(body.contains("req_test_anthropic"))
        }
    }

    @Test func settingsPersistenceAndLocalBehaviorForAnthropicBackend() throws {
        var settings = AppSettings()
        var claude = BackendConfig.anthropic(id: "claude-1", name: "Claude Sonnet")
        claude.anthropic?.model = "claude-sonnet-4-5"
        claude.anthropic?.vision = .yes
        claude.reasoning = ReasoningSettings(translate: "off", explain: "high")
        settings.backends.append(claude)
        settings.defaultBackendID = claude.id

        #expect(!claude.isBuiltIn)
        #expect(!claude.isOnDevice)
        #expect(claude.defaultReadingMode == .free)
        #expect(!settings.localCandidates.contains { $0.id == claude.id })

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(decoded == settings)
        let decodedClaude = try #require(decoded.backend(id: "claude-1"))
        #expect(decodedClaude.type == .anthropic)
        #expect(decodedClaude.anthropic?.model == "claude-sonnet-4-5")
        #expect(decodedClaude.reasoning == ReasoningSettings(translate: "off", explain: "high"))

        var mutable = decoded
        mutable.removeBackend(id: "claude-1")
        #expect(mutable.backend(id: "claude-1") == nil)
        #expect(mutable.defaultBackendID == BackendConfig.appleIntelligence.id)
    }
}

private actor AnthropicThinkingFlag {
    var count = 0
    func increment() { count += 1 }
}

private final class AnthropicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class AnthropicStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String, String)?
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var sent: [URLRequest] = []

    static func setHandler(_ value: @escaping Handler) {
        lock.withLock { handler = value; sent = [] }
    }

    static func requests() -> [URLRequest] { lock.withLock { sent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var logged = request
        if logged.httpBody == nil, let stream = logged.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            logged.httpBody = data
        }
        let currentHandler = Self.lock.withLock { () -> Handler? in
            Self.sent.append(logged)
            return Self.handler
        }
        guard let (status, body, contentType) = currentHandler?(logged) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType, "request-id": "req_test_anthropic"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(body.utf8)
        for offset in stride(from: 0, to: data.count, by: 7) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
