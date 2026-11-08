import Foundation
import Security

protocol AccessTokenStoring {
    func load() -> String?
    func readForEvaluation() throws -> String?
    @discardableResult func save(_ token: String) -> Bool
    func clear()
}

extension AccessTokenStoring {
    func readForEvaluation() throws -> String? { load() }
}

/// Bearer token lives in the Keychain next to the provider API keys.
struct KeychainAccessTokenStore: AccessTokenStoring {
    static let key = "memanager.access.sessionToken"

    func load() -> String? {
        KeychainManager.load(key: KeychainAccessTokenStore.key)
    }

    func readForEvaluation() throws -> String? {
        guard let data = try KeychainManager.readBinaryWithoutInteraction(key: Self.key) else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainReadError(status: errSecDecode)
        }
        return token
    }

    @discardableResult
    func save(_ token: String) -> Bool {
        KeychainManager.save(key: KeychainAccessTokenStore.key, value: token)
    }

    func clear() {
        KeychainManager.delete(key: KeychainAccessTokenStore.key)
    }
}

/// In memory store for tests and previews.
final class MemoryAccessTokenStore: AccessTokenStoring {
    private(set) var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func load() -> String? { token }

    @discardableResult
    func save(_ token: String) -> Bool {
        self.token = token
        return true
    }

    func clear() { token = nil }
}
