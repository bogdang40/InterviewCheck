import Foundation
import LocalAuthentication
import Security

enum KeychainManager {
    private static let service = "com.memanager.api"

    /// Whether the data protection keychain is usable in this process.
    /// Requires proper code signing entitlements. Production falls back to
    /// the legacy keychain after errSecMissingEntitlement. XCTest uses process
    /// memory before reaching any Security I/O. Reads preserve existing items.
    private static let capabilityLock = NSLock()
    private static var dataProtectionCapable: Bool?

    private static func dataProtectionAllowed() -> Bool {
        capabilityLock.withLock { dataProtectionCapable != false }
    }

    private static func markDataProtectionUnavailable() {
        capabilityLock.withLock { dataProtectionCapable = false }
    }

    private static func baseQuery(key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    // MARK: - String Storage

    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            NSLog("[KeychainManager] ERROR: Failed to convert value to data")
            return false
        }
        return upsert(key: key, data: data)
    }

    /// Add first, update on duplicate. The previous delete-then-add sequence
    /// had a window in which a crash or add failure destroyed the stored
    /// secret; with update-in-place the old value survives until the new one
    /// is committed.
    private static func upsert(key: String, data: Data) -> Bool {
        if TestRuntime.isRunningUnitTests {
            TestCredentialStore.shared.save(data, for: key)
            return true
        }
        if dataProtectionAllowed() {
            let result = upsert(key: key, data: data, dataProtection: true)
            switch result {
            case .success:
                return true
            case .missingEntitlement:
                markDataProtectionUnavailable()
            case .failed:
                return false
            }
        }
        return upsert(key: key, data: data, dataProtection: false) == .success
    }

    private enum UpsertResult {
        case success
        case missingEntitlement
        case failed
    }

    private static func upsert(key: String, data: Data, dataProtection: Bool) -> UpsertResult {
        var addQuery = baseQuery(key: key, dataProtection: dataProtection)
        addQuery[kSecAttrAccessible as String] = dataProtection
            ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            : kSecAttrAccessibleWhenUnlocked
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return .success
        }
        if addStatus == errSecMissingEntitlement {
            return .missingEntitlement
        }
        guard addStatus == errSecDuplicateItem else {
            NSLog("[KeychainManager] ERROR: SecItemAdd failed for key '\(key)' with status=\(addStatus)")
            return .failed
        }

        let updateStatus = SecItemUpdate(
            baseQuery(key: key, dataProtection: dataProtection) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecMissingEntitlement {
            return .missingEntitlement
        }
        if updateStatus != errSecSuccess {
            NSLog("[KeychainManager] ERROR: SecItemUpdate failed for key '\(key)' with status=\(updateStatus)")
            return .failed
        }
        return .success
    }

    static func load(key: String) -> String? {
        guard let data = loadBinary(key: key),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        if TestRuntime.isRunningUnitTests {
            TestCredentialStore.shared.remove(key)
            return true
        }
        var deleted = true
        if dataProtectionAllowed() {
            let status = SecItemDelete(baseQuery(key: key, dataProtection: true) as CFDictionary)
            if status == errSecMissingEntitlement {
                markDataProtectionUnavailable()
            } else {
                deleted = status == errSecSuccess || status == errSecItemNotFound
            }
        }
        let legacyStatus = SecItemDelete(baseQuery(key: key, dataProtection: false) as CFDictionary)
        return deleted && (legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound)
    }

    // MARK: - Binary Data Storage

    /// Saves binary data to Keychain. Returns true on success.
    static func saveBinary(key: String, data: Data) -> Bool {
        upsert(key: key, data: data)
    }

    /// Compatibility read for callers that represent unavailable keys as nil.
    /// Reading never migrates or deletes an existing credential.
    static func loadBinary(key: String) -> Data? {
        try? readBinaryWithoutInteraction(key: key)
    }

    /// Distinguishes absence from denied or unavailable storage. Noninteractive
    /// authentication does not make Security IPC asynchronous; use a worker queue.
    static func readBinaryWithoutInteraction(
        key: String,
        copyMatching: (CFDictionary) -> (OSStatus, Data?) = copyMatchingData
    ) throws -> Data? {
        for dataProtection in [true, false] {
            if dataProtection && !dataProtectionAllowed() { continue }
            let (status, data) = copyMatching(noninteractiveReadQuery(key: key, dataProtection: dataProtection) as CFDictionary)
            if dataProtection, status == errSecMissingEntitlement {
                markDataProtectionUnavailable()
                continue
            }
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw KeychainReadError(status: status) }
            guard let data else { throw KeychainReadError(status: errSecDecode) }
            return data
        }
        return nil
    }

    static func noninteractiveReadQuery(key: String, dataProtection: Bool) -> [String: Any] {
        var query = baseQuery(key: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // Request the scoped compatibility policy for legacy items too. Legacy
        // Security IPC can still block; callers must use their worker queue.
        if !dataProtection {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    private static func copyMatchingData(_ query: CFDictionary) -> (OSStatus, Data?) {
        if TestRuntime.isRunningUnitTests {
            guard let key = (query as NSDictionary)[kSecAttrAccount as String] as? String else {
                return (errSecParam, nil)
            }
            guard let data = TestCredentialStore.shared.data(for: key) else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, data)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result as? Data)
    }

    /// Checks if a key exists in Keychain without loading the data.
    static func exists(key: String) -> Bool {
        if TestRuntime.isRunningUnitTests {
            return TestCredentialStore.shared.data(for: key) != nil
        }
        for dataProtection in [true, false] {
            if dataProtection && !dataProtectionAllowed() { continue }
            var query = baseQuery(key: key, dataProtection: dataProtection)
            query[kSecReturnData as String] = false
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if dataProtection, status == errSecMissingEntitlement {
                markDataProtectionUnavailable()
                continue
            }
            if status == errSecSuccess {
                return true
            }
        }
        return false
    }
}

struct KeychainReadError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain access is unavailable (status \(status)). Existing credentials were kept. Check access in Keychain Access, then retry."
    }
}
