import Foundation
import CryptoKit
import Security
import Darwin

enum OAuthLoopbackError: Error, Sendable {
    case unavailable(String)
    case cancelled
    case timedOut
}

/// Cryptographic random values and S256 PKCE helpers shared across browser OAuth flows.
enum OAuthPKCE {
    static func randomValue(byteCount: Int = 32) throws -> String {
        var data = Data(count: byteCount)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        guard result == errSecSuccess else {
            throw OAuthLoopbackError.unavailable("Secure sign-in could not be started.")
        }
        return base64URL(data)
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

/// An HTTP callback server bound only to IPv4 loopback. Descriptor ownership is synchronized with cancellation.
final class OAuthLoopbackListener: @unchecked Sendable {
    let redirectURI: URL
    private let callbackPath: String
    private let providerName: String
    private let lock = NSLock()
    private var descriptor: Int32
    private var connection: Int32 = -1
    private var cancelled = false

    init(callbackPath: String = "/auth/callback", providerName: String) throws {
        self.callbackPath = callbackPath
        self.providerName = providerName
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthLoopbackError.unavailable("Could not start the local \(providerName) sign-in listener.")
        }
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
            throw OAuthLoopbackError.unavailable("Could not start the local \(providerName) sign-in listener.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else {
            close(fd)
            throw OAuthLoopbackError.unavailable("Could not determine the \(providerName) callback address.")
        }
        descriptor = fd
        redirectURI = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))\(callbackPath)")!
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
            guard !stopped, fd >= 0 else { throw OAuthLoopbackError.cancelled }
            // Darwin does not reliably interrupt a blocking accept when a listener is shut down.
            // Poll a nonblocking descriptor so cancellation finishes promptly without closing a
            // descriptor another thread might still be using.
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else {
                throw OAuthLoopbackError.unavailable("The \(providerName) sign-in listener stopped unexpectedly.")
            }
            lock.lock()
            if cancelled { lock.unlock(); throw OAuthLoopbackError.cancelled }
            let accepted = accept(fd, nil, nil)
            if accepted < 0 {
                let failure = errno
                lock.unlock()
                if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR { continue }
                throw OAuthLoopbackError.unavailable("The \(providerName) callback could not be received.")
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
            if isCancelled { throw OAuthLoopbackError.cancelled }
            if let result { return result }
        }
    }

    static func receiveCallback(
        listener: OAuthLoopbackListener,
        timeoutNanoseconds: UInt64 = 600_000_000_000
    ) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withTaskCancellationHandler(operation: {
                    try await Task.detached { try listener.receive() }.value
                }, onCancel: { listener.cancel() })
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                listener.cancel()
                throw OAuthLoopbackError.timedOut
            }
            defer { group.cancelAll(); listener.cancel() }
            return try await group.next()!
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
              let components = URLComponents(string: String(parts[1])), components.path == callbackPath else {
            respond(fd, status: "404 Not Found", body: "This address is used for \(providerName) sign-in.")
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
        respond(fd, status: "200 OK", body: "\(providerName) sign-in received. Return to Kandong to finish connecting. You can close this tab.")
        return callback
    }

    private func respond(_ fd: Int32, status: String, body: String) {
        let message = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n\(body)"
        message.withCString { pointer in _ = send(fd, pointer, strlen(pointer), 0) }
    }
}
