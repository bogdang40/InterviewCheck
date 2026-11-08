import CryptoKit
import Foundation

/// Last known account state plus when we fetched it. Lets the app keep
/// working offline until the server issued grace deadline.
struct CachedAccessSnapshot: Codable, Equatable {
    let snapshot: AccessSnapshot
    let fetchedAt: Date
}

protocol AccessSnapshotCaching {
    func load() -> CachedAccessSnapshot?
    func save(_ cached: CachedAccessSnapshot)
    func clear()
}

/// UserDefaults holds the bytes; a Keychain resident key authenticates them
/// so editing the plist by hand cannot forge an active entitlement.
struct UserDefaultsAccessSnapshotCache: AccessSnapshotCaching {
    static let key = "interviewcheck.access.snapshot"
    static let macKeychainKey = "interviewcheck.access.snapshotMacKey"

    private struct Envelope: Codable {
        let payload: Data
        let mac: Data
    }

    private let defaults: UserDefaults
    private let macKeyProvider: () -> SymmetricKey?

    init(defaults: UserDefaults = AppDefaults.standard, macKeyProvider: @escaping () -> SymmetricKey? = UserDefaultsAccessSnapshotCache.keychainMacKey) {
        self.defaults = defaults
        self.macKeyProvider = macKeyProvider
    }

    func load() -> CachedAccessSnapshot? {
        guard let data = defaults.data(forKey: UserDefaultsAccessSnapshotCache.key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let key = macKeyProvider(),
              HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: key) else {
            return nil
        }
        return try? UserDefaultsAccessSnapshotCache.decoder.decode(CachedAccessSnapshot.self, from: envelope.payload)
    }

    func save(_ cached: CachedAccessSnapshot) {
        guard let payload = try? UserDefaultsAccessSnapshotCache.encoder.encode(cached), let key = macKeyProvider() else { return }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        guard let data = try? JSONEncoder().encode(Envelope(payload: payload, mac: mac)) else { return }
        defaults.set(data, forKey: UserDefaultsAccessSnapshotCache.key)
    }

    func clear() {
        defaults.removeObject(forKey: UserDefaultsAccessSnapshotCache.key)
    }

    /// Random 256 bit key created on first use and kept in the Keychain.
    static func keychainMacKey() -> SymmetricKey? {
        resolveMacKey(
            read: { try KeychainManager.readBinaryWithoutInteraction(key: macKeychainKey) },
            save: { KeychainManager.saveBinary(key: macKeychainKey, data: $0) }
        )
    }

    static func resolveMacKey(read: () throws -> Data?, save: (Data) -> Bool) -> SymmetricKey? {
        do {
            if let existing = try read() {
                guard existing.count == 32 else { return nil }
                return SymmetricKey(data: existing)
            }
        } catch {
            // Locked, denied, and unavailable are not absence. Never replace a
            // key we could not read, which would invalidate the retained cache.
            return nil
        }
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        return save(raw) ? fresh : nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

final class MemoryAccessSnapshotCache: AccessSnapshotCaching {
    private(set) var cached: CachedAccessSnapshot?

    init(cached: CachedAccessSnapshot? = nil) {
        self.cached = cached
    }

    func load() -> CachedAccessSnapshot? { cached }
    func save(_ cached: CachedAccessSnapshot) { self.cached = cached }
    func clear() { cached = nil }
}
