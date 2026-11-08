import Foundation

enum CredentialStatus: Equatable {
    case loading
    case saving
    case configured
    case missing
    case unavailable(String)
    case saveFailed(String)

    var message: String {
        switch self {
        case .loading: return "Loading the stored credential."
        case .saving: return "Saving the credential."
        case .configured: return "A credential is available. Test the connection in Providers."
        case .missing: return "No credential is stored. Add a key in Providers."
        case .unavailable(let message), .saveFailed(let message): return message
        }
    }
}

/// Synchronous consumers see memory only. Security IPC and file access stay on
/// a serial worker, and a newer edit invalidates every older completion.
final class CachedCredential<Value> {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let read: () throws -> Value?
    private let write: (Value?) throws -> Value?
    private var revision = 0
    private var cachedValue: Value?
    private var cachedStatus: CredentialStatus = .loading
    var onChange: (() -> Void)?

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.memanager.credentials", qos: .userInitiated),
        read: @escaping () throws -> Value?,
        write: @escaping (Value?) throws -> Value?
    ) {
        self.queue = queue
        self.read = read
        self.write = write
    }

    var value: Value? { lock.withLock { cachedValue } }
    var status: CredentialStatus { lock.withLock { cachedStatus } }

    func reload() {
        guard let token = begin(.loading, unlessSaving: true) else { return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.complete(Result { try self.read() }, token: token, saving: false)
        }
    }

    func save(_ value: Value?) {
        guard let token = begin(.saving) else { return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.complete(Result { try self.write(value) }, token: token, saving: true)
        }
    }

    /// For explicit profile mutations whose caller needs the persisted result.
    func recordPersisted(_ value: Value?) {
        lock.withLock {
            revision &+= 1
            cachedValue = value
            cachedStatus = value == nil ? .missing : .configured
        }
        notify()
    }

    private func begin(_ status: CredentialStatus, unlessSaving: Bool = false) -> Int? {
        let token: Int? = lock.withLock {
            if unlessSaving, cachedStatus == .saving { return nil }
            revision &+= 1
            cachedStatus = status
            return revision
        }
        if token != nil { notify() }
        return token
    }

    private func isCurrent(_ token: Int) -> Bool { lock.withLock { revision == token } }

    private func complete(_ result: Result<Value?, Error>, token: Int, saving: Bool) {
        let changed = lock.withLock {
            guard revision == token else { return false }
            switch result {
            case .success(let value):
                cachedValue = value
                cachedStatus = value == nil ? .missing : .configured
            case .failure(let error):
                if !saving { cachedValue = nil }
                cachedStatus = saving ? .saveFailed(error.localizedDescription) : .unavailable(error.localizedDescription)
            }
            return true
        }
        if changed { notify() }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

enum CredentialStorageError: Error, LocalizedError {
    case invalidEncoding
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The stored credential could not be decoded. Existing data was kept."
        case .saveFailed: return "The credential could not be saved to the Keychain. Check Keychain access and retry."
        }
    }
}

enum CredentialKeychain {
    static func readString(_ key: String) throws -> String? {
        guard let data = try KeychainManager.readBinaryWithoutInteraction(key: key) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw CredentialStorageError.invalidEncoding }
        return normalized(value)
    }

    static func writeString(_ value: String?, key: String) throws -> String? {
        let value = normalized(value)
        let saved = value.map { KeychainManager.save(key: key, value: $0) } ?? KeychainManager.delete(key: key)
        guard saved else { throw CredentialStorageError.saveFailed }
        return value
    }

    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
