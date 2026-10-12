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

/// Keychain-backed store. Items are readable after the first unlock (needed
/// for background location uploads). With `synchronized`, they travel with
/// iCloud Keychain to the user's other Apple devices (end-to-end encrypted
/// by Apple); otherwise they never leave this device.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let synchronized: Bool

    public init(service: String = "de.timschaller.leuchtturm", synchronized: Bool = false) {
        self.service = service
        self.synchronized = synchronized
    }

    /// Finds items in either mode, so switching modes never loses keys.
    private func baseQuery(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
        q[kSecAttrSynchronizable as String] = synchronized
        q[kSecAttrAccessible as String] = synchronized
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
        return Set(list.compactMap { $0[kSecAttrAccount as String] as? String }).sorted()
    }

    /// Re-saves every item in this store's mode (sync on or off).
    public func migrateAll() throws {
        for account in try accounts() {
            if let data = try load(account) { try save(data, for: account) }
        }
    }
}
#endif
