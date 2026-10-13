import Foundation
import Testing
@testable import KandongKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct ChatGPTBackendTests {
    private func backend(model: String = "", vision: VisionSupport = .auto, reasoning: ReasoningSettings = .modelDefault, state: ChatGPTBackendState = ChatGPTBackendState()) -> ChatGPTBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStubProtocol.self]
        let session = URLSession(configuration: config)
        var settings = ChatGPTSettings()
        settings.model = model
        settings.vision = vision
        settings.reasoning = reasoning
        return ChatGPTBackend(settings: settings, urlSession: session, state: state, tokenProvider: { "test-bearer" })
    }

    private static let catalog = #"{"models":[{"slug":"hidden","visibility":"hidden"},{"slug":"first","display_name":"First model","visibility":"list","supports_images":true},{"slug":"second","display_name":"Second model","visibility":"list"}]}"#
    private static func event(_ type: String, _ fields: [String: JSONValue] = [:]) throws -> String {
        var json = fields
        json["type"] = .string(type)
        return "event: \(type)\ndata: " + String(decoding: try JSONValue.object(json).encoded(), as: UTF8.self) + "\n\n"
    }
    private static func success(_ text: String = "Hello") throws -> String {
        try event("response.output_text.delta", ["delta": .string(text)])
            + event("response.completed", ["response": ["status": "completed"]])
    }
    private static func stub(_ sse: String, status: Int = 200) {
        ChatGPTStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            return (status, sse, status == 200 ? "text/event-stream" : "application/json")
        }
    }

    @Test func requiresAnExplicitAccountAndPlanPermissionBeforeNetwork() async throws {
        let account = ChatGPTAccount(clientID: "account", issuer: "https://auth.openai.com", subject: "subject",
                                     scopes: ["chatgpt.tokens.use.direct"], isSignedIn: true)
        let session = ChatGPTSession(store: ChatGPTBackendStore(records: [ChatGPTCredential(account: account,
            accessToken: "test-bearer", expiresAt: Date().addingTimeInterval(3600))]))
        Self.stub(try Self.success())
        let noSelection = ChatGPTBackend(settings: ChatGPTSettings(), session: session)
        let status = await noSelection.status()
        #expect(!status.isReady && status.fix == .connectChatGPT)
        #expect(ChatGPTStubProtocol.requests().isEmpty)
        var denied = account
        denied.scopes = []
        let deniedSession = ChatGPTSession(store: ChatGPTBackendStore(records: [ChatGPTCredential(account: denied,
            accessToken: "test-bearer", expiresAt: Date().addingTimeInterval(3600))]))
        var settings = ChatGPTSettings()
        settings.accountID = account.id
        let noPermission = ChatGPTBackend(settings: settings, session: deniedSession)
        let deniedStatus = await noPermission.status()
        #expect(!deniedStatus.isReady && deniedStatus.fix == .connectChatGPT)
        await #expect(throws: ChatGPTError.self) {
            _ = try await noPermission.complete(AIRequest(system: "", user: "Hi"))
        }
        #expect(ChatGPTStubProtocol.requests().isEmpty)
    }

    @Test func signOutCancelsTheSelectedAccountsInFlightRequest() async throws {
        ChatGPTStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            return nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStubProtocol.self]
        let network = URLSession(configuration: config)
        let account = ChatGPTAccount(clientID: "account", issuer: "https://auth.openai.com", subject: "subject",
                                     scopes: ["chatgpt.tokens.use.direct"], isSignedIn: true)
        let session = ChatGPTSession(store: ChatGPTBackendStore(records: [ChatGPTCredential(account: account,
            accessToken: "test-bearer", expiresAt: Date().addingTimeInterval(3600))]), urlSession: network)
        var settings = ChatGPTSettings()
        settings.accountID = account.id
        var backend = ChatGPTBackend(settings: settings, session: session, urlSession: network)
        backend.timeLimit = 5
        let lookup = Task { try await backend.complete(AIRequest(system: "", user: "Hi")) }
        for _ in 0..<200 {
            if ChatGPTStubProtocol.requests().contains(where: { $0.url?.path == "/v1/responses" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ChatGPTStubProtocol.requests().contains(where: { $0.url?.path == "/v1/responses" }))
        let started = Date()
        try await session.signOut(accountID: account.id)
        do {
            _ = try await lookup.value
            Issue.record("The signed-out account's lookup should be cancelled")
        } catch {
            #expect(Date().timeIntervalSince(started) < 2)
        }
        #expect(!(await backend.status().isReady))
    }

    @Test func discoversAccountModelsInServerOrderAndUsesFirstVisible() async throws {
        Self.stub(try Self.success())
        let backend = backend()
        let models = try await backend.models()
        #expect(models.map(\.id) == ["first", "second"])
        #expect(models.map(\.displayName) == ["First model", "Second model"])
        #expect(try await backend.complete(AIRequest(system: "Translate", user: "你好")) == "Hello")
        let requests = ChatGPTStubProtocol.requests()
        let request = try #require(requests.last)
        let body = try JSONValue.decode(try #require(request.httpBody))
        #expect(body["model"]?.string == "first")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
    }

    @Test func mapsStructuredPromptsImagesAndPerTaskReasoningToResponses() async throws {
        Self.stub(try Self.success(#"{"translation":"Good morning"}"#))
        let backend = backend(reasoning: ReasoningSettings(translate: "off", explain: "high"))
        let request = AIRequest(system: "Translate this image", user: "早上好", image: Data([1, 2, 3]), schema: Prompts.translationSchema)
        _ = try await backend.complete(request)
        let sent = try #require(ChatGPTStubProtocol.requests().last?.httpBody)
        let body = try JSONValue.decode(sent)
        #expect(body["instructions"]?.string == request.system)
        #expect(body["store"]?.bool == false)
        #expect(body["stream"]?.bool == true)
        #expect(body["text"]?["format"]?["schema"] == Prompts.translationSchema)
        #expect(body["text"]?["format"]?["strict"]?.bool == true)
        #expect(body["reasoning"]?["effort"]?.string == "none")
        let input = try #require(body["input"]?.array?.first)
        #expect(input["role"]?.string == "user")
        let content = try #require(input["content"]?.array)
        #expect(content[0]["type"]?.string == "input_text")
        #expect(content[1]["type"]?.string == "input_image")
        #expect(content[1]["image_url"]?.string == "data:image/png;base64,AQID")
        let explanation = backend.body(for: AIRequest(system: "Explain", user: "你好", task: .explain), model: "first")
        #expect(explanation["reasoning"]?["effort"]?.string == "high")
        for key in ["max_output_tokens", "temperature", "messages", "response_format", "previous_response_id", "metadata", "conversation"] {
            #expect(body[key] == nil, "The ChatGPT plan route must omit \(key)")
        }
        #expect(self.backend().body(for: request, model: "first")["reasoning"] == nil)
    }

    @Test func preservesLearnReverseAndReadingCorrectionSchemas() async throws {
        let backend = backend()
        for schema in [Prompts.learnSchema, Prompts.reverseSchema, Prompts.translationSchema] {
            let request = AIRequest(system: "Translate and correct readings", user: "今天", schema: schema)
            #expect(backend.body(for: request, model: "first")["text"]?["format"]?["schema"] == schema)
        }
    }

    @Test func visionDefaultsToCatalogMetadataAndRespectsOverrides() async throws {
        Self.stub(try Self.success())
        #expect(await backend().supportsImages())
        #expect(!(await backend(model: "second").supportsImages()))
        #expect(await backend(model: "second", vision: .yes).supportsImages())
        #expect(!(await backend(vision: .no).supportsImages()))
    }

    @Test func neverFallsBackFromAnUnavailableConfiguredModel() async throws {
        Self.stub(try Self.success())
        await #expect(throws: BackendError.self) {
            _ = try await backend(model: "different-account-model").complete(AIRequest(system: "", user: "Hi"))
        }
        #expect(ChatGPTStubProtocol.requests().allSatisfy { $0.url?.path == "/v1/models" })
    }

    @Test func handlesFragmentedCRLFMultiLineSSEAndSignalsThinkingOnce() async throws {
        let thinking = ChatGPTThinkingFlag()
        let text = ": keepalive\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"你好 🌞\"}\r\n\r\n"
        Self.stub(try Self.event("response.reasoning_summary_text.delta", ["delta": "Thinking"])
            + Self.event("response.reasoning_summary_text.delta", ["delta": "More"])
            + text + Self.event("response.completed", ["response": ["status": "completed"]]))
        var request = AIRequest(system: "", user: "Hi")
        request.onThinking = { await thinking.increment() }
        #expect(try await backend().complete(request) == "你好 🌞")
        #expect(await thinking.count == 1)
    }

    @Test func requiresCompletedAfterPartialOutputAndLegacyDone() async throws {
        for ending in ["", "data: [DONE]\n\n", try Self.event("response.incomplete")] {
            Self.stub(try Self.event("response.output_text.delta", ["delta": "partial"]) + ending)
            await #expect(throws: BackendError.cutOff(name: "ChatGPT · first")) {
                _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
            }
        }
    }

    @Test func catchesUsageLimitAfterStreamingBegins() async throws {
        Self.stub(try Self.event("response.output_text.delta", ["delta": "partial"])
            + Self.event("response.failed", ["response": ["error": [
                "code": "subscription_sharing_usage_limit_exceeded", "message": "This app's limit was reached."
            ]]]))
        do {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
            Issue.record("Expected a usage error after the text delta")
        } catch ChatGPTError.usageLimit(let message) {
            #expect(message.contains("subscription_sharing_usage_limit_exceeded"))
            #expect(message.contains("request-test"))
        }
    }

    @Test func usageStatusSurvivesBackendRecreationAndClearsAfterExplicitSuccess() async throws {
        let state = ChatGPTBackendState()
        Self.stub(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"App limit"}}"#, status: 429)
        await #expect(throws: ChatGPTError.self) {
            _ = try await backend(state: state).complete(AIRequest(system: "", user: "Hi"))
        }
        Self.stub(try Self.success())
        let replacement = backend(state: state)
        let status = await replacement.status()
        #expect(!status.isReady)
        #expect(status.fix == .openURL(ChatGPTBackend.usageURL, label: "Manage usage"))
        #expect(ChatGPTStubProtocol.requests().isEmpty, "Known usage errors survive catalog checks")
        await #expect(throws: ChatGPTError.self) {
            _ = try await replacement.complete(AIRequest(system: "", user: "Hi"))
        }
        #expect(ChatGPTStubProtocol.requests().isEmpty, "Pause requests until the user checks usage again")
        await state.clear(accountID: "test-account")
        #expect(try await replacement.complete(AIRequest(system: "", user: "Hi")) == "Hello")
        #expect(await replacement.status().isReady)
        await state.recordUsageLimit("App limit", accountID: "test-account")
        await state.clear(accountID: "test-account")
        #expect(await replacement.status().isReady)
    }

    @Test func anOlderSuccessfulRequestDoesNotClearANewerUsageFailure() async {
        let state = ChatGPTBackendState()
        let admission = await state.requestState(accountID: "account")
        await state.recordUsageLimit("App limit", accountID: "account")
        await state.clear(accountID: "account", ifUnchanged: admission.revision)
        #expect(await state.usageLimit(accountID: "account") == "App limit")
        #expect(await state.usageLimit(accountID: "another-account") == nil)
    }

    @Test func surfacesDirectAdmissionDetailsWithoutLeakingBearer() async throws {
        Self.stub(#"{"detail":"Restricted for test-bearer"}"#, status: 403)
        do {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
            Issue.record("Expected an admission error")
        } catch BackendError.http(let status, let diagnostic) {
            #expect(status == 403)
            #expect(diagnostic.contains("Restricted"))
            #expect(diagnostic.contains("request-test"))
            #expect(!diagnostic.contains("test-bearer"))
        }
    }

    @Test func usageUnavailableKeepsCredentialsAndDoesNotRetry() async throws {
        Self.stub(#"{"error":{"code":"subscription_sharing_usage_unavailable","message":"Try later"}}"#, status: 503)
        await #expect(throws: ChatGPTError.self) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }
        #expect(ChatGPTStubProtocol.requests().filter { $0.url?.path == "/v1/responses" }.count == 1)
    }

    @Test func recognizesRefusalAndExplicitFailure() async throws {
        Self.stub(try Self.event("response.refusal.delta", ["delta": "I cannot"])
            + Self.event("response.completed"))
        await #expect(throws: BackendError.refused(name: "ChatGPT · first")) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }
        Self.stub(try Self.event("error", ["code": "bad_request", "message": "Unsupported input"]))
        await #expect(throws: BackendError.self) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }
    }

    @Test func stopsRepetitionAndMalformedStreams() async throws {
        Self.stub(try Self.success(String(repeating: "Oops. ", count: 100)))
        await #expect(throws: BackendError.repeating(name: "ChatGPT · first")) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }
        Self.stub("data: {invalid}\n\n")
        await #expect(throws: BackendError.self) {
            _ = try await backend().complete(AIRequest(system: "", user: "Hi"))
        }
    }

    @Test func timesOutAndCancelsNetworkRequests() async throws {
        ChatGPTStubProtocol.setHandler { request in
            if request.url?.path == "/v1/models" { return (200, Self.catalog, "application/json") }
            return nil // Leave the HTTP request open until cancellation.
        }
        var backend = backend()
        backend.timeLimit = 1
        let started = Date()
        await #expect(throws: BackendError.timedOut(name: "ChatGPT", seconds: 1)) {
            _ = try await backend.complete(AIRequest(system: "", user: "Hi"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(ChatGPTStubProtocol.cancelledCount() > 0)
    }
}

private actor ChatGPTThinkingFlag {
    var count = 0
    func increment() { count += 1 }
}

/// Delivers network fragments, rather than whole SSE lines, to the real URLSession transport.
private final class ChatGPTStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String, String)?
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var sent: [URLRequest] = []
    private static var cancelled = 0
    static func setHandler(_ value: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = value; sent = []; cancelled = 0
    }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    static func cancelledCount() -> Int { lock.lock(); defer { lock.unlock() }; return cancelled }
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
        Self.lock.lock()
        Self.sent.append(logged)
        let handler = Self.handler
        Self.lock.unlock()
        guard let (status, body, contentType) = handler?(logged) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType, "x-request-id": "request-test"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(body.utf8)
        for offset in stride(from: 0, to: data.count, by: 7) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cancelled += 1
    }
}

private struct ChatGPTBackendStore: ChatGPTCredentialStore {
    let records: [ChatGPTCredential]
    func load() throws -> [ChatGPTCredential] { records }
    func save(_ credential: ChatGPTCredential) throws {}
    func hostID() throws -> String { "test-host" }
}
