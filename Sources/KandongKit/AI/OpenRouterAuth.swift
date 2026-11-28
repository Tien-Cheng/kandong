import Foundation

public enum OpenRouterAuthError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidCallback
    case untrustedOrigin
    case exchangeFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "OpenRouter sign-in was cancelled."
        case .invalidCallback:
            return "OpenRouter sign-in could not be verified. Please try again."
        case .untrustedOrigin:
            return "OpenRouter browser sign-in keys can only be saved and sent to https://openrouter.ai."
        case .exchangeFailed(let message), .unavailable(let message):
            return message
        }
    }
}

/// Metadata returned by `GET https://openrouter.ai/api/v1/key`.
public struct OpenRouterKeyInfo: Codable, Equatable, Sendable {
    public let label: String?
    public let usage: Double?
    public let limit: Double?
    public let limitRemaining: Double?
    public let isFreeTier: Bool?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case limitRemaining = "limit_remaining"
        case isFreeTier = "is_free_tier"
    }

    public init(label: String? = nil, usage: Double? = nil, limit: Double? = nil,
                limitRemaining: Double? = nil, isFreeTier: Bool? = nil) {
        self.label = label
        self.usage = usage
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.isFreeTier = isFreeTier
    }
}

/// Pure attempt-scoped state for OpenRouter browser sign-in so cancelled or superseded attempts
/// cannot persist credentials, clear a newer sign-in's connecting state, or overwrite its messages.
public struct OpenRouterSignInState: Equatable, Sendable {
    public private(set) var activeAttemptID: UUID?
    public private(set) var connectingBackendID: String?
    public private(set) var messages: [String: String] = [:]
    public private(set) var keyVersion: [String: Int] = [:]

    public init() {}

    /// Starts a new sign-in attempt for `backendID`, returning its unique attempt ID or `nil` if another sign-in is active.
    public mutating func begin(backendID: String) -> UUID? {
        guard activeAttemptID == nil else { return nil }
        let id = UUID()
        activeAttemptID = id
        connectingBackendID = backendID
        messages[backendID] = ""
        return id
    }

    /// Synchronously cancels the active attempt so its commit hook and teardown become no-ops.
    @discardableResult
    public mutating func cancel() -> String? {
        let backendID = connectingBackendID
        activeAttemptID = nil
        connectingBackendID = nil
        if let backendID {
            messages[backendID] = "Sign-in cancelled."
        }
        return backendID
    }

    /// True only while `attemptID` is still the current, uncancelled attempt for `backendID`.
    public func canCommit(attemptID: UUID, backendID: String, isCancelled: Bool) -> Bool {
        !isCancelled && activeAttemptID == attemptID && connectingBackendID == backendID
    }

    /// Marks `attemptID` complete if it is still the active attempt.
    @discardableResult
    public mutating func succeed(attemptID: UUID, backendID: String) -> Bool {
        guard activeAttemptID == attemptID, connectingBackendID == backendID else { return false }
        activeAttemptID = nil
        connectingBackendID = nil
        keyVersion[backendID, default: 0] += 1
        messages[backendID] = ""
        return true
    }

    /// Marks `attemptID` failed if it is still the active attempt.
    @discardableResult
    public mutating func fail(attemptID: UUID, backendID: String, message: String) -> Bool {
        guard activeAttemptID == attemptID, connectingBackendID == backendID else { return false }
        activeAttemptID = nil
        connectingBackendID = nil
        messages[backendID] = message
        return true
    }

    public mutating func setMessage(_ message: String, for backendID: String) {
        messages[backendID] = message
    }

    public mutating func bumpKeyVersion(for backendID: String) {
        keyVersion[backendID, default: 0] += 1
    }

    public mutating func removeBackend(_ backendID: String) {
        if connectingBackendID == backendID {
            activeAttemptID = nil
            connectingBackendID = nil
        }
        messages[backendID] = nil
        keyVersion[backendID] = nil
    }
}

/// Official OpenRouter OAuth PKCE flow for desktop apps (`https://openrouter.ai/docs/guides/overview/auth/oauth`).
public actor OpenRouterAuth {
    public static let authURL = URL(string: "https://openrouter.ai/auth")!
    public static let exchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    public static let keysURL = URL(string: "https://openrouter.ai/settings/keys")!
    public static let referer = "https://github.com/tiencheng/kandong"
    public static let appTitle = "Kandong"

    private let urlSession: URLSession
    private let authEndpoint: URL
    private let exchangeEndpoint: URL
    private let now: @Sendable () -> Date
    private var authorizationID: UUID?
    private var callbackListener: OAuthLoopbackListener?

    public init(
        urlSession: URLSession = .shared,
        authEndpoint: URL = OpenRouterAuth.authURL,
        exchangeEndpoint: URL = OpenRouterAuth.exchangeURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.urlSession = urlSession
        self.authEndpoint = authEndpoint
        self.exchangeEndpoint = exchangeEndpoint
        self.now = now
    }

    /// True only for the official OpenRouter HTTPS origin (`https://openrouter.ai` on default port 443, no userinfo).
    public static func isOfficialOrigin(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "openrouter.ai",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return false
        }
        return true
    }

    public func cancelAuthorization() {
        authorizationID = nil
        callbackListener?.cancel()
        callbackListener = nil
    }

    /// Verifies that the target backend points to the official HTTPS OpenRouter origin both before launching
    /// browser sign-in and immediately before persisting the exchanged key, keeping the same attempt guard
    /// active through commit so cancelled or superseded attempts cannot persist credentials.
    public func authorizeAndSave(
        currentBaseURL: @escaping @Sendable () async -> String?,
        saveKey: @escaping @Sendable (String) async throws -> Void,
        openBrowser: @escaping @Sendable (URL) async throws -> Void
    ) async throws {
        cancelAuthorization()
        let attemptID = UUID()
        let startedAt = now()
        authorizationID = attemptID
        defer {
            if authorizationID == attemptID {
                authorizationID = nil
                callbackListener?.cancel()
                callbackListener = nil
            }
        }
        guard let initialURL = await currentBaseURL(), Self.isOfficialOrigin(initialURL) else {
            throw OpenRouterAuthError.untrustedOrigin
        }
        try checkAttempt(attemptID, startedAt: startedAt)
        let key = try await runAuthorization(attemptID: attemptID, startedAt: startedAt, openBrowser: openBrowser)
        try checkAttempt(attemptID, startedAt: startedAt)
        guard let finalURL = await currentBaseURL(), Self.isOfficialOrigin(finalURL) else {
            throw OpenRouterAuthError.untrustedOrigin
        }
        try checkAttempt(attemptID, startedAt: startedAt)
        try await saveKey(key)
        try checkAttempt(attemptID, startedAt: startedAt)
    }

    /// Starts the local loopback listener, opens the browser for OpenRouter PKCE approval, and exchanges the code for a scoped API key.
    public func authorize(
        openBrowser: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> String {
        cancelAuthorization()
        let attemptID = UUID()
        let startedAt = now()
        authorizationID = attemptID
        defer {
            if authorizationID == attemptID {
                authorizationID = nil
                callbackListener?.cancel()
                callbackListener = nil
            }
        }
        return try await runAuthorization(attemptID: attemptID, startedAt: startedAt, openBrowser: openBrowser)
    }

    private func runAuthorization(
        attemptID: UUID,
        startedAt: Date,
        openBrowser: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> String {
        let verifier: String
        let callbackNonce: String
        let listener: OAuthLoopbackListener
        do {
            verifier = try OAuthPKCE.randomValue()
            callbackNonce = try OAuthPKCE.randomValue(byteCount: 16)
            // Embed a per-attempt random path segment because OpenRouter's PKCE endpoint does not echo a `state` parameter.
            listener = try OAuthLoopbackListener(callbackPath: "/auth/callback/\(callbackNonce)", providerName: "OpenRouter")
        } catch let error as OAuthLoopbackError {
            throw Self.mapLoopbackError(error)
        }
        callbackListener = listener
        defer {
            listener.cancel()
            if authorizationID == attemptID {
                callbackListener = nil
            }
        }

        let challenge = OAuthPKCE.codeChallenge(for: verifier)
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: listener.redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw OpenRouterAuthError.unavailable("Could not build the OpenRouter sign-in URL.")
        }

        return try await withTaskCancellationHandler(operation: {
            try await openBrowser(url)
            try checkAttempt(attemptID, startedAt: startedAt)
            let callback: [String: String]
            do {
                callback = try await OAuthLoopbackListener.receiveCallback(listener: listener)
            } catch let error as OAuthLoopbackError {
                throw Self.mapLoopbackError(error)
            }
            try checkAttempt(attemptID, startedAt: startedAt)
            let code = try Self.validateCallback(callback)
            let key = try await Self.exchange(code: code, verifier: verifier, endpoint: exchangeEndpoint, network: urlSession)
            try checkAttempt(attemptID, startedAt: startedAt)
            return key
        }, onCancel: { listener.cancel() })
    }

    static func validateCallback(_ callback: [String: String]) throws -> String {
        if let error = callback["error"] {
            if error == "access_denied" { throw OpenRouterAuthError.cancelled }
            throw OpenRouterAuthError.exchangeFailed("OpenRouter sign-in did not complete. Please try again.")
        }
        guard let code = callback["code"], !code.isEmpty else {
            throw OpenRouterAuthError.invalidCallback
        }
        return code
    }

    /// Queries OpenRouter's `/key` endpoint to verify an API key and inspect its metadata.
    /// Never sends credentials off the official `https://openrouter.ai` origin.
    public static func keyInfo(
        apiKey: String,
        baseURL: String = OpenAIPreset.openRouter.baseURL,
        urlSession: URLSession = .shared
    ) async throws -> OpenRouterKeyInfo {
        guard isOfficialOrigin(baseURL) else {
            throw OpenRouterAuthError.untrustedOrigin
        }
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/key") else {
            throw BackendError.serverUnavailable(name: "OpenRouter", url: trimmed, hint: "Check the server URL in Settings.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.badResponse("OpenRouter returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: apiKey, with: "[redacted]")
            throw BackendError.http(status: http.statusCode, body: body)
        }
        struct Envelope: Decodable { let data: OpenRouterKeyInfo }
        if let decoded = try? JSONDecoder().decode(Envelope.self, from: data) {
            return decoded.data
        }
        return OpenRouterKeyInfo()
    }

    private func checkAttempt(_ id: UUID, startedAt: Date) throws {
        try Task.checkCancellation()
        guard authorizationID == id else { throw OpenRouterAuthError.cancelled }
        guard now().timeIntervalSince(startedAt) < 600 else {
            throw OpenRouterAuthError.exchangeFailed("OpenRouter sign-in expired. Please try again.")
        }
    }

    private static func exchange(
        code: String,
        verifier: String,
        endpoint: URL,
        network: URLSession
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object([
            "code": .string(code),
            "code_verifier": .string(verifier),
            "code_challenge_method": .string("S256"),
        ]).encoded()

        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterAuthError.unavailable("OpenRouter could not be reached.")
        }
        guard http.statusCode == 200 else {
            // Never echo raw upstream error bodies verbatim in case secrets appear in diagnostics.
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw OpenRouterAuthError.exchangeFailed("OpenRouter rejected the sign-in code. Please try again.")
            }
            throw OpenRouterAuthError.exchangeFailed("OpenRouter sign-in failed (HTTP \(http.statusCode)). Please try again.")
        }
        guard let json = try? JSONValue.decode(data),
              let key = json["key"]?.string, !key.isEmpty else {
            throw OpenRouterAuthError.exchangeFailed("OpenRouter did not return an API key. Please try again.")
        }
        return key
    }

    private static func mapLoopbackError(_ error: OAuthLoopbackError) -> OpenRouterAuthError {
        switch error {
        case .cancelled: return .cancelled
        case .timedOut: return .exchangeFailed("OpenRouter sign-in expired. Please try again.")
        case .unavailable(let message): return .unavailable(message)
        }
    }
}
