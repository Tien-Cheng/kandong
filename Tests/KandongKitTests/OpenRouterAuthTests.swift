import Foundation
import Testing
import CryptoKit
@testable import KandongKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct OpenRouterAuthTests {
    @Test func pkceFlowExchangesCodeForAPIKeyWithPerAttemptCallbackNonce() async throws {
        let fixture = OpenRouterAuthFixture()
        let auth = OpenRouterAuth(urlSession: fixture.network())
        let key = try await auth.authorize { url in
            try await fixture.openBrowser(url)
        }

        #expect(key == "sk-or-v1-minted-key")
        let query = try #require(fixture.authQueries.first)
        #expect(query["code_challenge_method"] == "S256")
        let callbackString = try #require(query["callback_url"])
        let callbackURL = try #require(URL(string: callbackString))
        #expect(callbackURL.host == "127.0.0.1")
        #expect(callbackURL.path.hasPrefix("/auth/callback/"))
        #expect(callbackURL.path.count > "/auth/callback/".count + 10)

        let body = try #require(fixture.exchangeBodies.first)
        #expect(body["code"]?.string == "or-auth-code")
        #expect(body["code_challenge_method"]?.string == "S256")
        let verifier = try #require(body["code_verifier"]?.string)
        #expect(OAuthPKCE.codeChallenge(for: verifier) == query["code_challenge"])
    }

    @Test func wrongCallbackPathIsRejectedWith404AndListenerKeepsWaiting() async throws {
        let fixture = OpenRouterAuthFixture()
        let auth = OpenRouterAuth(urlSession: fixture.network())

        let key = try await auth.authorize { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let validCallback = URL(string: query["callback_url"]!)!
            var wrongPath = URLComponents(url: validCallback, resolvingAgainstBaseURL: false)!
            wrongPath.path = "/auth/callback/wrong-nonce"
            wrongPath.queryItems = [URLQueryItem(name: "code", value: "attacker-code")]

            Task {
                if let (_, response) = try? await URLSession.shared.data(from: wrongPath.url!) {
                    #expect((response as? HTTPURLResponse)?.statusCode == 404)
                }
                var good = URLComponents(url: validCallback, resolvingAgainstBaseURL: false)!
                good.queryItems = [URLQueryItem(name: "code", value: "or-auth-code")]
                _ = try? await URLSession.shared.data(from: good.url!)
            }
        }
        #expect(key == "sk-or-v1-minted-key")
        #expect(fixture.exchangeBodies.first?["code"]?.string == "or-auth-code")
    }

    @Test func rejectsMissingCodeAccessDeniedAndExchangeFailures() async throws {
        #expect(throws: OpenRouterAuthError.invalidCallback) {
            _ = try OpenRouterAuth.validateCallback([:])
        }
        #expect(throws: OpenRouterAuthError.cancelled) {
            _ = try OpenRouterAuth.validateCallback(["error": "access_denied"])
        }
        #expect(throws: OpenRouterAuthError.self) {
            _ = try OpenRouterAuth.validateCallback(["error": "server_error"])
        }

        let fixture = OpenRouterAuthFixture()
        fixture.exchangeStatus = 401
        let auth = OpenRouterAuth(urlSession: fixture.network())
        await #expect(throws: OpenRouterAuthError.self) {
            _ = try await auth.authorize { url in try await fixture.openBrowser(url) }
        }

        fixture.exchangeStatus = 200
        fixture.exchangeResponse = #"{"user_id":"u1"}"#
        await #expect(throws: OpenRouterAuthError.self) {
            _ = try await auth.authorize { url in try await fixture.openBrowser(url) }
        }
    }

    @Test func cancellationClosesLoopbackListenerPromptly() async throws {
        let auth = OpenRouterAuth()
        let box = OpenRouterURLBox()
        let task = Task {
            try await auth.authorize { url in box.set(url) }
        }
        for _ in 0..<100 where box.value == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let opened = try #require(box.value)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: opened, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let callback = try #require(URL(string: query["callback_url"]!))

        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: callback) }
    }

    @Test func openRouterBackendValidatesKeyDetectsVisionAndSendsAttributionHeaders() async throws {
        let config = BackendConfig.openAI(.openRouter, id: "or-1")
        let missing = OpenAICompatibleBackend(config: config, apiKey: nil, urlSession: OpenRouterStubProtocol.session())
        let missingStatus = await missing.status()
        #expect(!missingStatus.isReady)
        #expect(missingStatus.fix == .connectOpenRouter(backendID: "or-1"))

        // Even if /models returns 200 (it's public on OpenRouter), /key returning 401 must fail status.
        OpenRouterStubProtocol.setHandler { request in
            if request.url?.path == "/api/v1/key" { return (401, #"{"error":"invalid"}"#, "application/json") }
            if request.url?.path == "/api/v1/models" {
                return (200, #"{"data":[{"id":"anthropic/claude-sonnet-4.5","architecture":{"input_modalities":["text","image"]}}]}"#, "application/json")
            }
            return (200, "", "application/json")
        }
        let rejected = OpenAICompatibleBackend(config: config, apiKey: "bad-key", urlSession: OpenRouterStubProtocol.session())
        let rejectedStatus = await rejected.status()
        #expect(!rejectedStatus.isReady)
        #expect(rejectedStatus.fix == .connectOpenRouter(backendID: "or-1"))

        // Valid key passes /key, auto-detects vision from architecture.input_modalities, and attaches attribution headers.
        OpenRouterStubProtocol.setHandler { request in
            switch request.url?.path {
            case "/api/v1/key":
                return (200, #"{"data":{"label":"Kandong","usage":0.5,"limit":10.0,"limit_remaining":9.5,"is_free_tier":false}}"#, "application/json")
            case "/api/v1/models":
                return (200, #"{"data":[{"id":"anthropic/claude-sonnet-4.5","architecture":{"input_modalities":["text","image"]}},{"id":"text/only","architecture":{"input_modalities":["text"]}}]}"#, "application/json")
            case "/api/v1/chat/completions":
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"
                return (200, sse, "text/event-stream")
            default:
                return (404, "", "application/json")
            }
        }
        var configured = config
        configured.openAI?.model = "anthropic/claude-sonnet-4.5"
        let ready = OpenAICompatibleBackend(config: configured, apiKey: "sk-or-valid", urlSession: OpenRouterStubProtocol.session())
        #expect(await ready.status() == .ready("anthropic/claude-sonnet-4.5"))
        #expect(await ready.supportsImages())

        var textOnly = config
        textOnly.openAI?.model = "text/only"
        let noVision = OpenAICompatibleBackend(config: textOnly, apiKey: "sk-or-valid", urlSession: OpenRouterStubProtocol.session())
        #expect(!(await noVision.supportsImages()))

        let reply = try await ready.complete(AIRequest(system: "Translate", user: "你好"))
        #expect(reply == "Hello")
        let completionReq = try #require(OpenRouterStubProtocol.requests().last { $0.url?.path == "/api/v1/chat/completions" })
        #expect(completionReq.value(forHTTPHeaderField: "HTTP-Referer") == OpenRouterAuth.referer)
        #expect(completionReq.value(forHTTPHeaderField: "X-Title") == OpenRouterAuth.appTitle)
        #expect(completionReq.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-valid")
    }

    @Test func officialOriginChecksSchemeHostPortAndUserinfo() {
        #expect(OpenRouterAuth.isOfficialOrigin("https://openrouter.ai/api/v1"))
        #expect(OpenRouterAuth.isOfficialOrigin("https://OPENROUTER.AI:443/api/v1"))
        #expect(!OpenRouterAuth.isOfficialOrigin("http://openrouter.ai/api/v1"))
        #expect(!OpenRouterAuth.isOfficialOrigin("https://openrouter.ai:8443/api/v1"))
        #expect(!OpenRouterAuth.isOfficialOrigin("https://user@openrouter.ai/api/v1"))
        #expect(!OpenRouterAuth.isOfficialOrigin("https://evil.example/api/v1"))
        #expect(!OpenRouterAuth.isOfficialOrigin("https://openrouter.ai.evil.example/api/v1"))
    }

    @Test func urlChangeDuringSignInRefusesToSaveBrowserIssuedKey() async throws {
        let fixture = OpenRouterAuthFixture()
        let auth = OpenRouterAuth(urlSession: fixture.network())
        let currentURL = OpenRouterStringBox("https://openrouter.ai/api/v1")
        let savedKey = OpenRouterStringBox(nil)

        await #expect(throws: OpenRouterAuthError.untrustedOrigin) {
            try await auth.authorizeAndSave(
                currentBaseURL: { currentURL.value },
                saveKey: { savedKey.set($0) },
                openBrowser: { url in
                    // User edits Server URL away from the official origin while browser sign-in is open.
                    currentURL.set("https://evil.example/api/v1")
                    try await fixture.openBrowser(url)
                }
            )
        }
        #expect(savedKey.value == nil)
    }

    @Test func browserIssuedKeyIsNeverSentOffOfficialHTTPSOrigin() async throws {
        for badURL in [
            "http://openrouter.ai/api/v1",
            "https://openrouter.ai:8443/api/v1",
            "https://evil.example/api/v1",
        ] {
            OpenRouterStubProtocol.setHandler { _ in (200, "{}", "application/json") }
            var config = BackendConfig.openAI(.openRouter, id: "or-origin")
            config.openAI?.baseURL = badURL
            let backend = OpenAICompatibleBackend(
                config: config,
                apiKey: "sk-or-v1-browser-secret",
                isOpenRouterOAuthKey: true,
                urlSession: OpenRouterStubProtocol.session()
            )
            let status = await backend.status()
            #expect(!status.isReady)
            #expect(status.message.contains("https://openrouter.ai"))
            #expect(!(await backend.supportsImages()))
            await #expect(throws: OpenRouterAuthError.untrustedOrigin) {
                _ = try await backend.complete(AIRequest(system: "Translate", user: "你好"))
            }
            #expect(OpenRouterStubProtocol.requests().isEmpty, "OAuth key must never be sent to \(badURL)")
        }

        OpenRouterStubProtocol.setHandler { _ in (200, "{}", "application/json") }
        await #expect(throws: OpenRouterAuthError.untrustedOrigin) {
            _ = try await OpenRouterAuth.keyInfo(
                apiKey: "sk-or-v1-browser-secret",
                baseURL: "http://openrouter.ai/api/v1",
                urlSession: OpenRouterStubProtocol.session()
            )
        }
        #expect(OpenRouterStubProtocol.requests().isEmpty)
    }
}

private final class OpenRouterStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(_ initial: String?) { stored = initial }
    var value: String? { lock.withLock { stored } }
    func set(_ value: String?) { lock.withLock { stored = value } }
}

private final class OpenRouterURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    var value: URL? { lock.withLock { url } }
    func set(_ value: URL) { lock.withLock { url = value } }
}

private final class OpenRouterAuthFixture: @unchecked Sendable {
    private let lock = NSLock()
    var exchangeStatus = 200
    var exchangeResponse = #"{"key":"sk-or-v1-minted-key","user_id":"user_123"}"#
    private(set) var authQueries: [[String: String]] = []
    private(set) var exchangeBodies: [JSONValue] = []

    func network() -> URLSession {
        OpenRouterStubProtocol.setHandler { [self] request in
            guard request.url?.path == "/api/v1/auth/keys" else {
                return (404, "", "application/json")
            }
            if let data = request.httpBody, let json = try? JSONValue.decode(data) {
                lock.withLock { exchangeBodies.append(json) }
            }
            return (exchangeStatus, exchangeResponse, "application/json")
        }
        return OpenRouterStubProtocol.session()
    }

    func openBrowser(_ url: URL) async throws {
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        lock.withLock { authQueries.append(fields) }
        var callback = URLComponents(string: fields["callback_url"]!)!
        callback.queryItems = [URLQueryItem(name: "code", value: "or-auth-code")]
        let callbackURL = callback.url!
        Task { _ = try? await URLSession.shared.data(from: callbackURL) }
    }
}

private final class OpenRouterStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String, String)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var sent: [URLRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenRouterStubProtocol.self]
        return URLSession(configuration: config)
    }

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
        let (status, body, contentType) = currentHandler?(logged) ?? (500, "", "application/json")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
