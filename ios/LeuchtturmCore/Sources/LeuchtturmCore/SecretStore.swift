import Foundation
import Synchronization

/// Storage for key material. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
    func accounts() throws -> [String]
}

extension SecretStore {
    func deleteAll(prefix: String) throws {
        for account in try accounts() where account.hasPrefix(prefix) {
            try delete(account)
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])

    public init() {}

    public func load(_ account: String) throws -> Data? { storage.withLock { $0[account] } }
    public func save(_ data: Data, for account: String) throws { storage.withLock { $0[account] = data } }
    public func delete(_ account: String) throws { _ = storage.withLock { $0.removeValue(forKey: account) } }
    public func accounts() throws -> [String] { storage.withLock { Array($0.keys) } }
}

#if canImport(Security)
import Security

public struct KeychainError: Error, Sendable, Equatable {
    public let status: OSStatus
}

/// Keychain-backed store. Items are available after first unlock (needed for
/// background location uploads), never leave this device and are not synced
/// to iCloud.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "de.timschaller.leuchtturm") {
        self.service = service
    }

    private func baseQuery(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func load(_ account: String) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func save(_ data: Data, for account: String) throws {
        try delete(account)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func accounts() throws -> [String] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else { throw KeychainError(status: status) }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
#endif
