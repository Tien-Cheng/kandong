import Foundation
import CryptoKit
import Security
import Darwin

/// A saved registration is distinct from other registrations, including those with the same email.
public struct ChatGPTAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String { clientID }
    public let clientID: String
    public let issuer: String
    public let subject: String
    public let email: String?
    public let name: String?
    public let label: String
    public var scopes: [String]
    public var isSignedIn: Bool
    public var hasPlanPermission: Bool { scopes.contains("chatgpt.tokens.use.direct") }

    public init(clientID: String, issuer: String, subject: String, email: String? = nil, name: String? = nil,
                label: String? = nil, scopes: [String], isSignedIn: Bool) {
        self.clientID = clientID
        self.issuer = issuer
        self.subject = subject
        self.email = email
        self.name = name
        // Include a registration suffix so identical email addresses remain distinguishable.
        self.label = label ?? "\(email ?? name ?? "ChatGPT account") · \(clientID.suffix(8))"
        self.scopes = scopes
        self.isSignedIn = isSignedIn
    }
}

public struct ChatGPTCredential: Codable, Sendable {
    public var account: ChatGPTAccount
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var earliestRefreshAt: Date?

    public init(account: ChatGPTAccount, accessToken: String? = nil, refreshToken: String? = nil,
                idToken: String? = nil, expiresAt: Date? = nil, earliestRefreshAt: Date? = nil) {
        self.account = account
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.earliestRefreshAt = earliestRefreshAt
    }
}

/// Implementations must protect secrets and atomically replace a registration's entire credential record.
public protocol ChatGPTCredentialStore: Sendable {
    func load() throws -> [ChatGPTCredential]
    func save(_ credential: ChatGPTCredential) throws
    func hostID() throws -> String
}

public enum ChatGPTError: Error, LocalizedError, Sendable {
    case signedOut
    case planPermissionMissing
    case cancelled
    case invalidCallback
    case invalidIdentity
    case oauth(String)
    case usageLimit(String)
    case unavailable(String)
    case revocationUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Connect your ChatGPT account to continue."
        case .planPermissionMissing: return "Reconnect ChatGPT and allow Kandong to use your ChatGPT plan."
        case .cancelled: return "ChatGPT sign-in was cancelled."
        case .invalidCallback: return "ChatGPT sign-in could not be verified. Please try again."
        case .invalidIdentity: return "ChatGPT returned an account identity that could not be verified. Please try again."
        case .oauth(let message), .usageLimit(let message), .unavailable(let message): return message
        case .revocationUnconfirmed: return "You are signed out locally, but remote sign-out could not be confirmed. Disconnect Kandong in ChatGPT Settings if needed."
        }
    }
}

public actor ChatGPTSession {
    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private let store: any ChatGPTCredentialStore
    private let urlSession: URLSession
    private let now: @Sendable () -> Date
    private var credentials: [String: ChatGPTCredential]?
    private var refreshes: [String: Task<ChatGPTCredential, Error>] = [:]
    private var generations: [String: UInt64] = [:]
    private var requests: [UUID: (accountID: String, cancel: @Sendable () -> Void)] = [:]
    private var authorizationID: UUID?
    private var authorizationAccountID: String?
    private var callbackListener: ChatGPTLoopbackListener?

    public init(store: any ChatGPTCredentialStore, urlSession: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.urlSession = urlSession
        self.now = now
    }

    private func loadCredentials() throws {
        guard credentials == nil else { return }
        // Keep the first record if storage contains duplicates instead of trapping.
        credentials = Dictionary(try store.load().map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func accounts() throws -> [ChatGPTAccount] {
        try loadCredentials()
        return credentials!.values.map(\.account).sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    public func requestGeneration(accountID: String) throws -> UInt64 {
        try loadCredentials()
        guard credentials?[accountID]?.account.isSignedIn == true else { throw ChatGPTError.signedOut }
        return generations[accountID, default: 0]
    }

    public func validateRequest(accountID: String, generation: UInt64) throws {
        guard credentials?[accountID]?.account.isSignedIn == true,
              generations[accountID, default: 0] == generation else { throw ChatGPTError.signedOut }
    }

    public func registerRequest(accountID: String, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        _ = try requestGeneration(accountID: accountID)
        guard credentials?[accountID]?.account.hasPlanPermission == true else { throw ChatGPTError.planPermissionMissing }
        let id = UUID()
        requests[id] = (accountID, cancel)
        return id
    }

    public func unregisterRequest(_ id: UUID) { requests.removeValue(forKey: id) }

    public func accessToken(for accountID: String) async throws -> String {
        try loadCredentials()
        guard let credential = credentials?[accountID], credential.account.isSignedIn else { throw ChatGPTError.signedOut }
        guard credential.account.hasPlanPermission else { throw ChatGPTError.planPermissionMissing }
        guard let token = credential.accessToken, !token.isEmpty else { throw ChatGPTError.signedOut }
        let time = now()
        if let expiry = credential.expiresAt, expiry > time.addingTimeInterval(60) { return token }
        if let earliest = credential.earliestRefreshAt, earliest > time {
            guard let expiry = credential.expiresAt, expiry > time else {
                throw ChatGPTError.unavailable("ChatGPT credentials cannot be renewed yet. Please try again shortly.")
            }
            return token
        }
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else { throw ChatGPTError.signedOut }
        let generation = generations[accountID, default: 0]
        let task: Task<ChatGPTCredential, Error>
        if let pending = refreshes[accountID] {
            task = pending
        } else {
            let network = urlSession
            let clock = now
            task = Task {
                let response = try await Self.exchange(network: network, fields: [
                    "grant_type": "refresh_token", "client_id": accountID,
                    "refresh_token": refreshToken, "resource": Self.resource,
                ])
                var updated = credential
                updated.accessToken = response.accessToken
                guard let replacement = response.refreshToken, !replacement.isEmpty else {
                    throw ChatGPTError.oauth("ChatGPT did not return renewable credentials. Please reconnect.")
                }
                updated.refreshToken = replacement
                if let idToken = response.idToken { updated.idToken = idToken }
                updated.account.scopes = response.scope?.split(separator: " ").map(String.init) ?? credential.account.scopes
                updated.expiresAt = response.expiresIn.map { clock().addingTimeInterval($0) }
                updated.earliestRefreshAt = response.earliestRefreshAt.map(Date.init(timeIntervalSince1970:))
                return updated
            }
            refreshes[accountID] = task
        }
        do {
            let updated = try await task.value
            try validateRequest(accountID: accountID, generation: generation)
            // Another waiter may have already committed this same rotation. Saving it again is harmless.
            try store.save(updated)
            credentials?[accountID] = updated
            refreshes[accountID] = nil
            guard updated.account.hasPlanPermission else { throw ChatGPTError.planPermissionMissing }
            return updated.accessToken!
        } catch {
            if generations[accountID, default: 0] == generation {
                refreshes[accountID] = nil
                if let failure = error as? TokenFailure, Self.unusableRefreshCodes.contains(failure.code) {
                    var cleared = credential
                    cleared.account.isSignedIn = false
                    cleared.accessToken = nil
                    cleared.refreshToken = nil
                    cleared.idToken = nil
                    cleared.expiresAt = nil
                    cleared.earliestRefreshAt = nil
                    credentials?[accountID] = cleared
                    generations[accountID, default: 0] += 1
                    let cancellations = requests.filter { $0.value.accountID == accountID }
                    for (id, request) in cancellations { requests.removeValue(forKey: id); request.cancel() }
                    try store.save(cleared)
                    throw ChatGPTError.signedOut
                }
            }
            if error is TokenFailure { throw ChatGPTError.oauth("ChatGPT could not renew this session. Please reconnect.") }
            throw error
        }
    }

    public func cancelAuthorization() {
        authorizationID = nil
        authorizationAccountID = nil
        callbackListener?.cancel()
        callbackListener = nil
    }

    /// The listener starts before the injected system-browser opener is called.
    public func authorize(accountID: String? = nil,
                          openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> ChatGPTAccount {
        try await authorizeAttempt(accountID: accountID, registrationID: nil, mayRetryCode: true, openBrowser: openBrowser)
    }

    private func authorizeAttempt(accountID: String?, registrationID: String?, mayRetryCode: Bool,
                                  openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> ChatGPTAccount {
        try loadCredentials()
        let startingGenerations = generations
        let previous: ChatGPTCredential?
        if let accountID {
            guard let saved = credentials?[accountID] else { throw ChatGPTError.signedOut }
            previous = saved
        } else { previous = nil }
        cancelAuthorization()
        let attemptID = UUID()
        let listener = try ChatGPTLoopbackListener()
        authorizationID = attemptID
        authorizationAccountID = accountID
        callbackListener = listener
        defer {
            listener.cancel()
            if authorizationID == attemptID {
                authorizationID = nil
                authorizationAccountID = nil
                callbackListener = nil
            }
        }
        let startedAt = now()
        let verifier = try Self.randomValue()
        let state = try Self.randomValue()
        let nonce = try Self.randomValue()
        var components = URLComponents(string: "\(Self.issuer)/api/accounts/authorize")!
        var query = [
            "client_id": previous?.account.clientID ?? registrationID ?? "dynamic_agent_client",
            "ext_agent_host_id": try store.hostID(),
            "response_type": "code", "redirect_uri": listener.redirectURI.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": Self.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
        ]
        if let previous {
            if let token = previous.idToken { query["id_token_hint"] = token }
            if let email = previous.account.email { query["login_hint"] = email }
            if !previous.account.hasPlanPermission { query["prompt"] = "consent" }
        } else if registrationID == nil { query["agent_name_hint"] = "Kandong" }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await withTaskCancellationHandler(operation: {
            try await openBrowser(components.url!)
            try checkAttempt(attemptID, startedAt: startedAt)
            let callback = try await Self.receiveCallback(listener: listener)
            try checkAttempt(attemptID, startedAt: startedAt)
            let issuedID = try Self.validateCallback(callback, state: state, previousClientID: previous?.account.clientID ?? registrationID)
            let response: TokenResponse
            do {
                response = try await Self.exchange(network: urlSession, fields: [
                    "grant_type": "authorization_code", "client_id": issuedID, "code": callback["code"]!,
                    "code_verifier": verifier, "redirect_uri": listener.redirectURI.absoluteString, "resource": Self.resource,
                ], requireBearer: false)
            } catch let failure as TokenFailure {
                try checkAttempt(attemptID, startedAt: startedAt)
                guard generations[issuedID, default: 0] == startingGenerations[issuedID, default: 0] else { throw ChatGPTError.cancelled }
                if failure.code == "invalid_grant", mayRetryCode {
                    // A code is single-use. Reopen authorization with fresh proof values and the issued registration.
                    return try await authorizeAttempt(accountID: accountID, registrationID: issuedID, mayRetryCode: false, openBrowser: openBrowser)
                }
                throw ChatGPTError.oauth("ChatGPT could not authorize this session. Please try again.")
            }
            try checkAttempt(attemptID, startedAt: startedAt)
            guard let idToken = response.idToken else { throw ChatGPTError.invalidIdentity }
            let identity = try await Self.validateIDToken(idToken, clientID: issuedID, nonce: nonce, network: urlSession, now: now())
            try checkAttempt(attemptID, startedAt: startedAt)
            if let previous {
                guard identity.subject == previous.account.subject, identity.issuer == previous.account.issuer else {
                    throw ChatGPTError.invalidIdentity
                }
            }
            let account = ChatGPTAccount(clientID: issuedID, issuer: identity.issuer, subject: identity.subject,
                                         email: identity.email, name: identity.name, label: previous?.account.label,
                                         scopes: response.scope?.split(separator: " ").map(String.init) ?? [], isSignedIn: true)
            let credential = ChatGPTCredential(account: account, accessToken: response.accessToken,
                                                refreshToken: response.refreshToken, idToken: idToken,
                                                expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
                                                earliestRefreshAt: response.earliestRefreshAt.map(Date.init(timeIntervalSince1970:)))
            // An existing registration's identity is immutable, including while adding accounts.
            guard generations[issuedID, default: 0] == startingGenerations[issuedID, default: 0] else { throw ChatGPTError.cancelled }
            if let existing = credentials?[issuedID],
               (existing.account.subject != identity.subject || existing.account.issuer != identity.issuer) {
                throw ChatGPTError.invalidIdentity
            }
            try store.save(credential)
            credentials?[issuedID] = credential
            generations[issuedID, default: 0] += 1
            return account
        }, onCancel: { listener.cancel() })
    }

    private func checkAttempt(_ id: UUID, startedAt: Date) throws {
        try Task.checkCancellation()
        guard authorizationID == id else { throw ChatGPTError.cancelled }
        guard now().timeIntervalSince(startedAt) < 600 else {
            throw ChatGPTError.oauth("ChatGPT sign-in expired. Please try again.")
        }
    }

    public func signOut(accountID: String) async throws {
        try loadCredentials()
        guard var credential = credentials?[accountID] else { return }
        if authorizationAccountID == accountID { cancelAuthorization() }
        generations[accountID, default: 0] += 1
        refreshes.removeValue(forKey: accountID)?.cancel()
        let cancellations = requests.filter { $0.value.accountID == accountID }
        for (id, request) in cancellations {
            requests.removeValue(forKey: id)
            request.cancel()
        }
        let refreshToken = credential.refreshToken
        credential.accessToken = nil
        credential.refreshToken = nil
        credential.idToken = nil
        credential.expiresAt = nil
        credential.earliestRefreshAt = nil
        credential.account.isSignedIn = false
        // Prevent further requests before the first network await, even if protected storage fails.
        credentials?[accountID] = credential
        let storageError: Error?
        do { try store.save(credential); storageError = nil }
        catch { storageError = error }
        guard let refreshToken else {
            if let storageError { throw storageError }
            return
        }
        var revocationConfirmed = false
        do {
            let discovery = try await Self.discovery(network: urlSession)
            guard let endpoint = discovery.revocationEndpoint, Self.trustedAuthURL(endpoint) else {
                throw ChatGPTError.revocationUnconfirmed
            }
            var confirmed = false
            // Retry transient failures twice while the token is still available in this stack frame.
            for attempt in 0..<3 {
                do {
                    let status = try await Self.post(network: urlSession, url: endpoint, fields: [
                        "token": refreshToken, "token_type_hint": "refresh_token", "client_id": accountID,
                    ]).1
                    if status == 200 { confirmed = true; break }
                    if status < 500 { break }
                } catch is CancellationError { throw CancellationError() }
                catch { if attempt == 2 { throw error } }
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 250_000_000) }
            }
            revocationConfirmed = confirmed
        } catch { revocationConfirmed = false }
        if let storageError {
            if !revocationConfirmed {
                throw ChatGPTError.unavailable("ChatGPT requests have stopped, but credentials could not be removed and remote sign-out was not confirmed. Disconnect Kandong in ChatGPT Settings.")
            }
            throw storageError
        }
        if !revocationConfirmed { throw ChatGPTError.revocationUnconfirmed }
    }

    static func validateCallback(_ callback: [String: String], state: String, previousClientID: String?) throws -> String {
        guard callback["state"] == state else { throw ChatGPTError.invalidCallback }
        if let error = callback["error"] {
            if error == "access_denied" { throw ChatGPTError.planPermissionMissing }
            throw ChatGPTError.oauth("ChatGPT sign-in did not complete. Please try again.")
        }
        guard let code = callback["code"], !code.isEmpty else { throw ChatGPTError.invalidCallback }
        if let previousClientID {
            guard callback["client_id"] == nil || callback["client_id"] == previousClientID else {
                throw ChatGPTError.invalidCallback
            }
            return previousClientID
        }
        guard let issuedID = callback["client_id"], !issuedID.isEmpty, issuedID != "dynamic_agent_client" else {
            throw ChatGPTError.invalidCallback
        }
        return issuedID
    }

    private static func receiveCallback(listener: ChatGPTLoopbackListener) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withTaskCancellationHandler(operation: {
                    try await Task.detached { try listener.receive() }.value
                }, onCancel: { listener.cancel() })
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 600_000_000_000)
                listener.cancel()
                throw ChatGPTError.oauth("ChatGPT sign-in expired. Please try again.")
            }
            defer { group.cancelAll(); listener.cancel() }
            return try await group.next()!
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let tokenType: String?
        let expiresIn: TimeInterval?
        let scope: String?
        let earliestRefreshAt: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
            case tokenType = "token_type", expiresIn = "expires_in", scope, earliestRefreshAt = "earliest_refresh_at"
        }
    }

    private struct TokenFailure: LocalizedError {
        let code: String
        var errorDescription: String? { "ChatGPT could not authorize this session. Please reconnect." }
    }
    private static let unusableRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]
    private static func exchange(network: URLSession, fields: [String: String], requireBearer: Bool = true) async throws -> TokenResponse {
        let (data, status) = try await post(network: network, url: tokenURL, fields: fields)
        guard status == 200 else {
            // Never echo server descriptions, since credentials may be included in diagnostic responses.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let code = object["error"] as? String ?? (object["error"] as? [String: Any])?["code"] as? String
                if let code { throw TokenFailure(code: code) }
            }
            throw ChatGPTError.oauth("ChatGPT could not renew or authorize this session. Please reconnect.")
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ChatGPTError.oauth("ChatGPT returned incomplete credentials. Please reconnect.")
        }
        let grantedDirect = response.scope?.split(separator: " ").contains("chatgpt.tokens.use.direct") == true
        if requireBearer || grantedDirect {
            guard let accessToken = response.accessToken, !accessToken.isEmpty,
                  response.tokenType?.caseInsensitiveCompare("Bearer") == .orderedSame,
                  let expiresIn = response.expiresIn, expiresIn.isFinite, expiresIn > 0 else {
                throw ChatGPTError.oauth("ChatGPT returned incomplete credentials. Please reconnect.")
            }
        }
        return response
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let string = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    private static func post(network: URLSession, url: URL, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.unavailable("ChatGPT could not be reached.") }
        return (data, http.statusCode)
    }

    private struct Discovery: Decodable {
        let issuer: String
        let jwksURI: URL
        let revocationEndpoint: URL?
        enum CodingKeys: String, CodingKey { case issuer, jwksURI = "jwks_uri", revocationEndpoint = "revocation_endpoint" }
    }
    private static func trustedAuthURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    private static func discovery(network: URLSession) async throws -> Discovery {
        let (data, response) = try await network.data(from: URL(string: "\(issuer)/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let discovery = try? JSONDecoder().decode(Discovery.self, from: data), discovery.issuer == issuer,
              trustedAuthURL(discovery.jwksURI) else { throw ChatGPTError.invalidIdentity }
        return discovery
    }

    private struct JWK: Decodable { let kty: String; let kid: String; let n: String?; let e: String?; let alg: String?; let use: String? }
    private struct JWKS: Decodable { let keys: [JWK] }
    struct Identity: Sendable { let issuer: String; let subject: String; let email: String?; let name: String? }
    static func validateIDToken(_ token: String, clientID: String, nonce: String, network: URLSession, now: Date) async throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = decodeBase64URL(String(parts[0])),
              let payloadData = decodeBase64URL(String(parts[1])), let signature = decodeBase64URL(String(parts[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let keyID = header["kid"] as? String,
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw ChatGPTError.invalidIdentity }
        let discovery = try await discovery(network: network)
        let (data, response) = try await network.data(from: discovery.jwksURI)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try? JSONDecoder().decode(JWKS.self, from: data),
              let key = jwks.keys.first(where: { $0.kid == keyID && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let modulus = key.n.flatMap(decodeBase64URL), let exponent = key.e.flatMap(decodeBase64URL),
              modulus.count >= 256, !exponent.isEmpty else { throw ChatGPTError.invalidIdentity }
        let keyData = der(tag: 0x30, bytes: derInteger(modulus) + derInteger(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil) else {
            throw ChatGPTError.invalidIdentity
        }
        let audiences: [String]
        if let audience = payload["aud"] as? String { audiences = [audience] }
        else { audiences = payload["aud"] as? [String] ?? [] }
        guard payload["iss"] as? String == issuer, audiences.contains(clientID),
              (audiences.count <= 1 || payload["azp"] as? String == clientID),
              let expiry = payload["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > now.timeIntervalSince1970,
              let issuedAt = payload["iat"] as? NSNumber, CFGetTypeID(issuedAt) != CFBooleanGetTypeID(),
              issuedAt.doubleValue.isFinite, issuedAt.doubleValue <= now.timeIntervalSince1970 + 30,
              issuedAt.doubleValue < expiry.doubleValue,
              payload["nonce"] as? String == nonce,
              let subject = payload["sub"] as? String, !subject.isEmpty else { throw ChatGPTError.invalidIdentity }
        if let value = payload["nbf"] {
            guard let notBefore = value as? NSNumber, CFGetTypeID(notBefore) != CFBooleanGetTypeID(),
                  notBefore.doubleValue.isFinite, notBefore.doubleValue <= now.timeIntervalSince1970 + 30 else { throw ChatGPTError.invalidIdentity }
        }
        return Identity(issuer: issuer, subject: subject, email: payload["email"] as? String, name: payload["name"] as? String)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var unsigned = bytes
        while unsigned.count > 1 && unsigned.first == 0 { unsigned.removeFirst() }
        if let first = unsigned.first, first & 0x80 != 0 { unsigned.insert(0, at: 0) }
        return der(tag: 0x02, bytes: unsigned)
    }
    private static func der(tag: UInt8, bytes: Data) -> Data {
        var header = Data([tag])
        if bytes.count < 128 { header.append(UInt8(bytes.count)) }
        else {
            var length = bytes.count
            var encoded: [UInt8] = []
            repeat { encoded.insert(UInt8(length & 0xff), at: 0); length >>= 8 } while length > 0
            header.append(0x80 | UInt8(encoded.count)); header.append(contentsOf: encoded)
        }
        return header + bytes
    }
    private static func randomValue() throws -> String {
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ChatGPTError.unavailable("Secure sign-in could not be started.") }
        return base64URL(data)
    }
    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ string: String) -> Data? {
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

/// An HTTP callback server bound only to IPv4 loopback. Descriptor ownership is synchronized with cancellation.
final class ChatGPTLoopbackListener: @unchecked Sendable {
    let redirectURI: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var connection: Int32 = -1
    private var cancelled = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatGPTError.unavailable("Could not start the local ChatGPT sign-in listener.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let flags = fcntl(fd, F_GETFL)
        guard bound == 0, listen(fd, 4) == 0, flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw ChatGPTError.unavailable("Could not start the local ChatGPT sign-in listener.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { close(fd); throw ChatGPTError.unavailable("Could not determine the ChatGPT callback address.") }
        descriptor = fd
        redirectURI = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/auth/callback")!
    }

    deinit { cancel(); if descriptor >= 0 { close(descriptor) } }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        // The reader owns close(). Shutdown interrupts recv without descriptor-reuse races.
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
    }

    func receive() throws -> [String: String] {
        while true {
            lock.lock()
            let fd = descriptor
            let stopped = cancelled
            lock.unlock()
            guard !stopped, fd >= 0 else { throw ChatGPTError.cancelled }
            // Darwin does not reliably interrupt a blocking accept when a listener is shut down.
            // Poll a nonblocking descriptor so cancellation finishes promptly without closing a
            // descriptor another thread might still be using.
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw ChatGPTError.unavailable("The ChatGPT sign-in listener stopped unexpectedly.") }
            lock.lock()
            if cancelled { lock.unlock(); throw ChatGPTError.cancelled }
            let accepted = accept(fd, nil, nil)
            if accepted < 0 {
                let failure = errno
                lock.unlock()
                if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR { continue }
                throw ChatGPTError.unavailable("The ChatGPT callback could not be received.")
            }
            connection = accepted
            lock.unlock()
            // Accepted sockets may inherit nonblocking mode on some platforms.
            let acceptedFlags = fcntl(accepted, F_GETFL)
            if acceptedFlags >= 0 { _ = fcntl(accepted, F_SETFL, acceptedFlags & ~O_NONBLOCK) }
            let result = receiveRequest(accepted)
            lock.lock()
            connection = -1
            close(accepted)
            let isCancelled = cancelled
            lock.unlock()
            if isCancelled { throw ChatGPTError.cancelled }
            if let result { return result }
        }
    }

    private func receiveRequest(_ fd: Int32) -> [String: String]? {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while data.count <= 16_384 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard data.count <= 16_384, let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              let components = URLComponents(string: String(parts[1])), components.path == "/auth/callback" else {
            respond(fd, status: "404 Not Found", body: "This address is used for ChatGPT sign-in.")
            return nil
        }
        var callback: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard callback[item.name] == nil, let value = item.value else {
                respond(fd, status: "400 Bad Request", body: "Sign-in could not be verified. Return to Kandong and try again.")
                return [:]
            }
            callback[item.name] = value
        }
        respond(fd, status: "200 OK", body: "ChatGPT sign-in received. Return to Kandong to finish connecting. You can close this tab.")
        return callback
    }

    private func respond(_ fd: Int32, status: String, body: String) {
        let message = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n\(body)"
        message.withCString { pointer in _ = send(fd, pointer, strlen(pointer), 0) }
    }
}
