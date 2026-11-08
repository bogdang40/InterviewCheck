import Foundation
import Security

/// What a connector needs to sign in: named fields (API key, subdomain,
/// account token) and, for OAuth connectors, the tokens.
public struct ConnectorCredentials: Codable, Equatable, Sendable {
    public var fields: [String: String]
    public var tokens: OAuthTokens?

    public init(fields: [String: String] = [:], tokens: OAuthTokens? = nil) {
        self.fields = fields
        self.tokens = tokens
    }

    public subscript(key: String) -> String? {
        let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public func required(_ key: String, _ label: String) throws -> String {
        guard let value = self[key] else { throw ConnectorError.missingCredential(label) }
        return value
    }
}

/// Where credentials live. The app uses the Keychain; tests use memory.
public protocol CredentialStore: Sendable {
    func load(_ account: String) -> ConnectorCredentials?
    func save(_ credentials: ConnectorCredentials, for account: String) throws
    func delete(_ account: String)
}

/// One Keychain item per connected account, as JSON.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func load(_ account: String) -> ConnectorCredentials? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectorCredentials.self, from: data)
    }

    public func save(_ credentials: ConnectorCredentials, for account: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConnectorError.invalidResponse("Keychain error \(status)")
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// In-memory store for tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var items: [String: ConnectorCredentials] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(_ account: String) -> ConnectorCredentials? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    public func save(_ credentials: ConnectorCredentials, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = credentials
    }

    public func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }
}
