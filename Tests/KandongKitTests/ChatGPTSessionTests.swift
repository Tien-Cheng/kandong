import Foundation
import Testing
import CryptoKit
import Security
@testable import KandongKit

@Suite(.serialized) struct ChatGPTSessionTests {
    private let time = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func callbackMustMatchAttemptAndRegistration() throws {
        #expect(try ChatGPTSession.validateCallback(["state": "state", "code": "code", "client_id": "issued"], state: "state", previousClientID: nil) == "issued")
        #expect(try ChatGPTSession.validateCallback(["state": "state", "code": "code"], state: "state", previousClientID: "saved") == "saved")
        for callback in [
            ["state": "wrong", "code": "code", "client_id": "issued"],
            ["state": "state", "code": "code"],
            ["state": "state", "code": "code", "client_id": "dynamic_agent_client"],
        ] {
            #expect(throws: (any Error).self) { try ChatGPTSession.validateCallback(callback, state: "state", previousClientID: nil) }
        }
        #expect(throws: (any Error).self) {
            try ChatGPTSession.validateCallback(["state": "state", "code": "code", "client_id": "other"], state: "state", previousClientID: "saved")
        }
        #expect(throws: (any Error).self) {
            try ChatGPTSession.validateCallback(["state": "wrong", "error": "access_denied"], state: "state", previousClientID: nil)
        }
    }

    @Test func formEncodingPreservesSecretsLiterally() {
        let data = ChatGPTSession.formBody(["token": "a+b &x=1/中文", "client_id": "registered"])
        #expect(String(data: data, encoding: .utf8) == "client_id=registered&token=a%2Bb%20%26x%3D1%2F%E4%B8%AD%E6%96%87")
    }

    @Test func registersWithFreshProofAndStoresValidatedIdentity() async throws {
        let fixture = try AuthFixture(time: time)
        let store = SessionMemoryStore()
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        let account = try await session.authorize(openBrowser: { url in try await fixture.openBrowser(url) })
        let request = try #require(fixture.authorizations.first)
        #expect(request["client_id"] == "dynamic_agent_client")
        #expect(request["agent_name_hint"] == "Kandong")
        #expect(request["ext_agent_host_id"] == store.stableHostID)
        #expect(request["code_challenge_method"] == "S256")
        #expect(request["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(account.clientID == "oaiapp_registered" && account.subject == "verified-user")
        #expect(account.email == "person@example.com" && account.isSignedIn && account.hasPlanPermission)
        #expect(try await session.accessToken(for: account.id) == "access-secret")
        let saved = try #require(store.snapshot().first)
        #expect(saved.refreshToken == "refresh-secret")
        #expect(saved.expiresAt == time.addingTimeInterval(3600))
        let exchanged = try #require(fixture.tokenFields.first)
        #expect(exchanged["redirect_uri"] == request["redirect_uri"])
        #expect(exchanged["client_id"] == account.id)
        #expect(exchanged["resource"] == "https://api.openai.com/v1")
        let verifier = try #require(exchanged["code_verifier"])
        #expect(ChatGPTSession.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == request["code_challenge"])
    }

    @Test func wrongReturningIdentityDoesNotReplaceWorkingAccount() async throws {
        let fixture = try AuthFixture(time: time)
        fixture.subject = "another-user"
        let original = credential()
        let store = SessionMemoryStore([original])
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        await #expect(throws: (any Error).self) { try await session.authorize(accountID: original.account.id, openBrowser: { url in try await fixture.openBrowser(url) }) }
        #expect(store.snapshot().first?.accessToken == original.accessToken)
        let request = try #require(fixture.authorizations.first)
        #expect(request["client_id"] == original.account.id)
        #expect(request["agent_name_hint"] == nil && request["prompt"] == nil)
        #expect(request["id_token_hint"] == "prior-id-token")
        #expect(request["login_hint"] == "person@example.com")
    }

    @Test func missingPlanPermissionRetainsSignInAndExplicitlyRequestsConsent() async throws {
        let fixture = try AuthFixture(time: time)
        fixture.scope = "openid email profile offline_access"
        fixture.identityOnly = true
        let store = SessionMemoryStore()
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        let account = try await session.authorize(openBrowser: { url in try await fixture.openBrowser(url) })
        #expect(account.isSignedIn && !account.hasPlanPermission)
        #expect(store.snapshot().first?.accessToken == nil && store.snapshot().first?.expiresAt == nil)
        #expect(store.snapshot().first?.idToken != nil)
        await #expect(throws: (any Error).self) { try await session.accessToken(for: account.id) }
        await #expect(throws: (any Error).self) { try await session.registerRequest(accountID: account.id, cancel: {}) }
        fixture.scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        fixture.identityOnly = false
        let enabled = try await session.authorize(accountID: account.id, openBrowser: { url in try await fixture.openBrowser(url) })
        #expect(enabled.hasPlanPermission)
        #expect(fixture.authorizations.last?["prompt"] == "consent")
    }

    @Test func invalidGrantStartsOneFreshAuthorizationUsingIssuedID() async throws {
        let fixture = try AuthFixture(time: time)
        fixture.invalidCodeAttempts = 1
        let session = ChatGPTSession(store: SessionMemoryStore(), urlSession: fixture.network(), now: { time })
        let account = try await session.authorize(openBrowser: { url in try await fixture.openBrowser(url) })
        #expect(account.isSignedIn)
        #expect(fixture.authorizations.count == 2)
        let first = fixture.authorizations[0], second = fixture.authorizations[1]
        #expect(second["client_id"] == "oaiapp_registered" && second["agent_name_hint"] == nil)
        #expect(first["state"] != second["state"] && first["nonce"] != second["nonce"])
        #expect(first["code_challenge"] != second["code_challenge"])
        fixture.invalidCodeAttempts = 3
        await #expect(throws: (any Error).self) { try await session.authorize(openBrowser: { url in try await fixture.openBrowser(url) }) }
        #expect(fixture.authorizations.count == 4, "An invalid code must not cause an unbounded browser loop")
    }

    @Test func verifiesSignatureIssuerAudienceNonceAndExpiry() async throws {
        let fixture = try AuthFixture(time: time)
        let network = fixture.network()
        let valid: [String: Any] = ["iss": "https://auth.openai.com", "aud": "client", "sub": "user", "iat": time.timeIntervalSince1970, "exp": time.timeIntervalSince1970 + 300, "nonce": "nonce"]
        let identity = try await ChatGPTSession.validateIDToken(fixture.sign(valid), clientID: "client", nonce: "nonce", network: network, now: time)
        #expect(identity.subject == "user")
        for (key, value) in [("iss", "https://other.example" as Any), ("aud", "other"), ("nonce", "other"), ("exp", time.timeIntervalSince1970 - 1), ("exp", true), ("iat", true), ("iat", time.timeIntervalSince1970 + 300), ("nbf", true), ("nbf", time.timeIntervalSince1970 + 300), ("sub", "")] {
            var invalid = valid
            invalid[key] = value
            let token = try fixture.sign(invalid)
            await #expect(throws: (any Error).self) {
                try await ChatGPTSession.validateIDToken(token, clientID: "client", nonce: "nonce", network: network, now: time)
            }
        }
        var missingIssuedAt = valid
        missingIssuedAt.removeValue(forKey: "iat")
        await #expect(throws: (any Error).self) {
            try await ChatGPTSession.validateIDToken(fixture.sign(missingIssuedAt), clientID: "client", nonce: "nonce", network: network, now: time)
        }
        let components = try fixture.sign(valid).split(separator: ".")
        let corrupted = "\(components[0]).\(components[1]).\(ChatGPTSession.base64URL(Data(repeating: 0, count: 256)))"
        await #expect(throws: (any Error).self) {
            try await ChatGPTSession.validateIDToken(corrupted, clientID: "client", nonce: "nonce", network: network, now: time)
        }
        var multiple = valid
        multiple["aud"] = ["client", "second"]
        await #expect(throws: (any Error).self) {
            try await ChatGPTSession.validateIDToken(fixture.sign(multiple), clientID: "client", nonce: "nonce", network: network, now: time)
        }
        multiple["azp"] = "client"
        _ = try await ChatGPTSession.validateIDToken(fixture.sign(multiple), clientID: "client", nonce: "nonce", network: network, now: time)
    }

    @Test func simultaneousRequestsShareOneRotatingRefresh() async throws {
        let fixture = try AuthFixture(time: time)
        let store = SessionMemoryStore([credential(expired: true)])
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await session.accessToken(for: "oaiapp_registered") } }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }
        #expect(Set(tokens) == ["access-secret"])
        #expect(fixture.tokenFields.count == 1)
        #expect(fixture.tokenFields[0]["grant_type"] == "refresh_token")
        #expect(fixture.tokenFields[0]["scope"] == nil)
        #expect(fixture.tokenFields[0]["refresh_token"] == "prior-refresh-token")
        #expect(store.snapshot().first?.refreshToken == "refresh-secret")
    }

    @Test func earliestRefreshTimePreventsPrematureRotation() async throws {
        let fixture = try AuthFixture(time: time)
        var saved = credential()
        saved.expiresAt = time.addingTimeInterval(20)
        saved.earliestRefreshAt = time.addingTimeInterval(10)
        let session = ChatGPTSession(store: SessionMemoryStore([saved]), urlSession: fixture.network(), now: { time })
        #expect(try await session.accessToken(for: saved.account.id) == "prior-access-token")
        #expect(fixture.tokenFields.isEmpty)
    }

    @Test func terminalRefreshClearsTokensWhileTransientFailurePreservesThem() async throws {
        for terminal in [false, true] {
            let fixture = try AuthFixture(time: time)
            fixture.tokenFailure = terminal ? "invalid_grant" : "temporarily_unavailable"
            let saved = credential(expired: true)
            let store = SessionMemoryStore([saved])
            let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
            await #expect(throws: (any Error).self) { try await session.accessToken(for: saved.account.id) }
            let result = try #require(store.snapshot().first)
            #expect(result.account.id == saved.account.id && result.account.subject == saved.account.subject)
            #expect(result.account.isSignedIn == !terminal)
            #expect((result.refreshToken == nil) == terminal)
        }
    }

    @Test func signOutCancelsRequestsAndClearsOnlySelectedAccountEvenIfRevokeFails() async throws {
        let fixture = try AuthFixture(time: time)
        fixture.revocationStatus = 503
        let other = credential(id: "oaiapp_other")
        let store = SessionMemoryStore([credential(), other])
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        let cancelled = SessionFlag()
        let generation = try await session.requestGeneration(accountID: "oaiapp_registered")
        _ = try await session.registerRequest(accountID: "oaiapp_registered", cancel: { cancelled.set() })
        await #expect(throws: (any Error).self) { try await session.signOut(accountID: "oaiapp_registered") }
        #expect(cancelled.value)
        await #expect(throws: (any Error).self) { try await session.validateRequest(accountID: "oaiapp_registered", generation: generation) }
        let signedOut = try #require(store.snapshot().first { $0.account.id == "oaiapp_registered" })
        #expect(!signedOut.account.isSignedIn && signedOut.accessToken == nil && signedOut.refreshToken == nil && signedOut.idToken == nil)
        #expect(store.snapshot().first { $0.account.id == other.account.id }?.accessToken == other.accessToken)
        #expect(fixture.revocations.count == 3)
        #expect(fixture.revocations[0]["token_type_hint"] == "refresh_token")
        #expect(fixture.revocations[0]["client_id"] == "oaiapp_registered")
        #expect(fixture.revocations[0]["token"] == "prior-refresh-token")
    }

    @Test func cancellationClosesListenerAndPreservesExistingAccount() async throws {
        let fixture = try AuthFixture(time: time)
        let store = SessionMemoryStore([credential()])
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        let opened = SessionURLBox()
        let task = Task { try await session.authorize(openBrowser: { url in opened.set(url) }) }
        for _ in 0..<100 where opened.value == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let authorization = try #require(opened.value)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let redirect = try #require(URL(string: query["redirect_uri"]!))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await #expect(throws: (any Error).self) { try await URLSession.shared.data(from: redirect) }
        #expect(store.snapshot().first?.accessToken == "prior-access-token")
    }

    @Test func failedProtectedStorageDoesNotReplaceCurrentConnection() async throws {
        let fixture = try AuthFixture(time: time)
        let saved = credential()
        let store = SessionMemoryStore([saved])
        store.failSave = true
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        await #expect(throws: (any Error).self) { try await session.authorize(accountID: saved.account.id, openBrowser: { url in try await fixture.openBrowser(url) }) }
        #expect(try await session.accessToken(for: saved.account.id) == saved.accessToken)
    }

    @Test func failedLocalRemovalStillRevokesAndStopsRequests() async throws {
        let fixture = try AuthFixture(time: time)
        let saved = credential()
        let store = SessionMemoryStore([saved])
        let session = ChatGPTSession(store: store, urlSession: fixture.network(), now: { time })
        store.failSave = true
        await #expect(throws: (any Error).self) { try await session.signOut(accountID: saved.account.id) }
        #expect(fixture.revocations.count == 1)
        #expect(try await session.accounts().first?.isSignedIn == false)
        await #expect(throws: (any Error).self) { try await session.accessToken(for: saved.account.id) }
    }

    @Test func expiredAuthorizationPreservesExistingConnection() async throws {
        let store = SessionMemoryStore([credential()])
        let clock = SessionClock(time)
        let session = ChatGPTSession(store: store, now: { clock.value })
        await #expect(throws: (any Error).self) {
            try await session.authorize(openBrowser: { _ in clock.advance(601) })
        }
        #expect(store.snapshot().first?.accessToken == "prior-access-token")
    }

    private func credential(id: String = "oaiapp_registered", expired: Bool = false) -> ChatGPTCredential {
        ChatGPTCredential(account: ChatGPTAccount(clientID: id, issuer: "https://auth.openai.com", subject: "verified-user", email: "person@example.com", scopes: ["chatgpt.tokens.use.direct", "openid"], isSignedIn: true),
                          accessToken: "prior-access-token", refreshToken: "prior-refresh-token", idToken: "prior-id-token", expiresAt: time.addingTimeInterval(expired ? -10 : 3600))
    }
}

private final class SessionMemoryStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ChatGPTCredential]
    var failSave = false
    let stableHostID = "urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    init(_ credentials: [ChatGPTCredential] = []) { records = Dictionary(uniqueKeysWithValues: credentials.map { ($0.account.id, $0) }) }
    func load() throws -> [ChatGPTCredential] { snapshot() }
    func snapshot() -> [ChatGPTCredential] { lock.lock(); defer { lock.unlock() }; return Array(records.values) }
    func save(_ credential: ChatGPTCredential) throws {
        lock.lock(); defer { lock.unlock() }
        if failSave { throw ChatGPTError.unavailable("Protected storage is unavailable.") }
        records[credential.account.id] = credential
    }
    func hostID() throws -> String { stableHostID }
}

private final class SessionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
private final class SessionURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    var value: URL? { lock.lock(); defer { lock.unlock() }; return url }
    func set(_ value: URL) { lock.lock(); url = value; lock.unlock() }
}
private final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ value: Date) { date = value }
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private final class AuthFixture: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    let time: Date
    private let privateKey: SecKey
    private let publicJWK: [String: String]
    var subject = "verified-user"
    var scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    var tokenFailure: String?
    var identityOnly = false
    var invalidCodeAttempts = 0
    var revocationStatus = 200
    private(set) var authorizations: [[String: String]] = []
    private(set) var tokenFields: [[String: String]] = []
    private(set) var revocations: [[String: String]] = []

    init(time: Date) throws {
        self.time = time
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        _ = Self.readDER(der, cursor: &cursor, headerOnly: true)
        let modulus = Self.readDER(der, cursor: &cursor)
        let exponent = Self.readDER(der, cursor: &cursor)
        publicJWK = ["kid": "test-key", "kty": "RSA", "alg": "RS256", "use": "sig", "n": ChatGPTSession.base64URL(modulus), "e": ChatGPTSession.base64URL(exponent)]
    }

    func network() -> URLSession {
        SessionURLProtocol.handler = { [self] request in try self.respond(request) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionURLProtocol.self]
        return URLSession(configuration: config)
    }

    func openBrowser(_ url: URL) async throws {
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        lock.withLock { authorizations.append(fields) }
        let clientID = fields["client_id"] == "dynamic_agent_client" ? "oaiapp_registered" : fields["client_id"]!
        var callback = URLComponents(string: fields["redirect_uri"]!)!
        callback.queryItems = [URLQueryItem(name: "code", value: "callback-code"), URLQueryItem(name: "state", value: fields["state"]), URLQueryItem(name: "client_id", value: clientID)]
        let callbackURL = callback.url!
        // The system browser launches independently; do not wait for the callback inside the opener.
        Task { _ = try? await URLSession.shared.data(from: callbackURL) }
    }

    func sign(_ payload: [String: Any]) throws -> String {
        let header = ChatGPTSession.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key"]))
        let body = ChatGPTSession.base64URL(try JSONSerialization.data(withJSONObject: payload))
        let content = "\(header).\(body)"
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(content.utf8) as CFData, nil)) as Data
        return "\(content).\(ChatGPTSession.base64URL(signature))"
    }

    private func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        switch request.url!.path {
        case "/.well-known/openid-configuration":
            return (200, try JSONSerialization.data(withJSONObject: ["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json", "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"]))
        case "/.well-known/jwks.json": return (200, try JSONSerialization.data(withJSONObject: ["keys": [publicJWK]]))
        case "/api/accounts/oauth/token":
            let fields = Self.requestFields(request)
            tokenFields.append(fields)
            if let tokenFailure { return (400, try JSONSerialization.data(withJSONObject: ["error": tokenFailure, "error_description": "sensitive-response-never-shown"])) }
            if fields["grant_type"] == "authorization_code", invalidCodeAttempts > 0 {
                invalidCodeAttempts -= 1
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            var response: [String: Any] = ["access_token": "access-secret", "refresh_token": "refresh-secret", "token_type": "Bearer", "expires_in": 3600, "scope": scope]
            if fields["grant_type"] == "authorization_code" {
                response["id_token"] = try sign(["iss": "https://auth.openai.com", "sub": subject, "aud": fields["client_id"]!, "nonce": authorizations.last!["nonce"]!, "iat": time.timeIntervalSince1970, "exp": time.timeIntervalSince1970 + 3600, "email": "person@example.com", "name": "Person"])
            }
            if identityOnly {
                response.removeValue(forKey: "access_token")
                response.removeValue(forKey: "refresh_token")
                response.removeValue(forKey: "token_type")
                response.removeValue(forKey: "expires_in")
            }
            return (200, try JSONSerialization.data(withJSONObject: response))
        case "/api/accounts/oauth/revoke":
            revocations.append(Self.requestFields(request))
            return (revocationStatus, Data())
        default: throw ChatGPTError.unavailable("Unexpected test endpoint.")
        }
    }

    private static func requestFields(_ request: URLRequest) -> [String: String] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let query = String(data: bytes, encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: URLComponents(string: "https://test.invalid/?\(query)")!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    private static func readDER(_ data: Data, cursor: inout Int, headerOnly: Bool = false) -> Data {
        cursor += 1
        let first = Int(data[cursor]); cursor += 1
        var length = first
        if first & 0x80 != 0 {
            length = 0
            for _ in 0..<(first & 0x7f) { length = (length << 8) | Int(data[cursor]); cursor += 1 }
        }
        if headerOnly { return Data() }
        var result = Data(data[cursor..<(cursor + length)])
        cursor += length
        while result.count > 1 && result.first == 0 { result.removeFirst() }
        return result
    }
}

private final class SessionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
