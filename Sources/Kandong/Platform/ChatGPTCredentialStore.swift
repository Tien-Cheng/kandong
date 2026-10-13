import Foundation
import Security
import KandongKit

/// One Keychain item per registration. UserDefaults contains only recognisable account metadata.
final class MacChatGPTCredentialStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let accountsKey = "chatgpt-account-metadata"
    private let hostKey = "chatgpt-host-id"
    private let service = "Kandong.ChatGPT"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func hostID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let value = defaults.string(forKey: hostKey) { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: hostKey)
        return value
    }

    func load() throws -> [ChatGPTCredential] {
        lock.lock()
        defer { lock.unlock() }
        return try metadata().map { account in
            guard account.isSignedIn else { return ChatGPTCredential(account: account) }
            var item: CFTypeRef?
            var query = keychainQuery(account.id)
            query[kSecReturnData as String] = true
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound {
                var signedOut = account
                signedOut.isSignedIn = false
                return ChatGPTCredential(account: signedOut)
            }
            guard status == errSecSuccess, let data = item as? Data else { throw storageError }
            return try JSONDecoder().decode(ChatGPTCredential.self, from: data)
        }
    }

    func save(_ credential: ChatGPTCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        var accounts = try metadata()
        if let index = accounts.firstIndex(where: { $0.id == credential.account.id }) {
            accounts[index] = credential.account
        } else {
            accounts.append(credential.account)
        }
        let metadata = try JSONEncoder().encode(accounts)
        if credential.accessToken == nil && credential.refreshToken == nil && credential.idToken == nil {
            // A locked Keychain must not make a signed-out registration active again after restart.
            defaults.set(metadata, forKey: accountsKey)
            let status = SecItemDelete(keychainQuery(credential.account.id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError }
        } else {
            let data = try JSONEncoder().encode(credential)
            let query = keychainQuery(credential.account.id)
            let attributes: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw storageError }
        }
        defaults.set(metadata, forKey: accountsKey)
    }

    private func metadata() throws -> [ChatGPTAccount] {
        guard let data = defaults.data(forKey: accountsKey) else { return [] }
        return try JSONDecoder().decode([ChatGPTAccount].self, from: data)
    }

    private func keychainQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    private var storageError: ChatGPTError {
        .unavailable("Couldn't access the ChatGPT credentials in your login Keychain. Unlock it and try again.")
    }
}

/// Rendering a preview must never inspect or modify the user's saved accounts.
struct PreviewChatGPTCredentialStore: ChatGPTCredentialStore {
    func load() throws -> [ChatGPTCredential] { [] }
    func save(_ credential: ChatGPTCredential) throws { throw ChatGPTError.unavailable("Sign-in is unavailable in previews.") }
    func hostID() throws -> String { "urn:uuid:00000000-0000-4000-8000-000000000000" }
}
