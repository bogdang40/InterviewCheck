import Foundation

final class VoiceCredentials {
    let accessKey = VoiceCredentials.string("memanager.voiceSignature.accessKey")
    let deepgramKey = VoiceCredentials.string("memanager.deepgram.apiKey")
    let profile = CachedCredential<Data>(
        read: { try KeychainManager.readBinaryWithoutInteraction(key: VoiceCredentials.profileKey) },
        write: { value in
            guard VoiceCredentials.persistProfile(value) else { throw CredentialStorageError.saveFailed }
            return value
        }
    )
    private static let profileKey = "memanager.voiceSignature.profile"
    var onChange: (() -> Void)?

    init() {
        accessKey.onChange = { [weak self] in self?.onChange?() }
        deepgramKey.onChange = { [weak self] in self?.onChange?() }
        profile.onChange = { [weak self] in self?.onChange?() }
    }

    func reload() {
        accessKey.reload()
        deepgramKey.reload()
        profile.reload()
    }

    func saveProfile(_ data: Data?) -> Bool {
        guard Self.persistProfile(data) else { return false }
        profile.recordPersisted(data)
        return true
    }

    private static func persistProfile(_ data: Data?) -> Bool {
        data.map { KeychainManager.saveBinary(key: profileKey, data: $0) }
            ?? KeychainManager.delete(key: profileKey)
    }

    private static func string(_ key: String) -> CachedCredential<String> {
        CachedCredential(
            read: { try CredentialKeychain.readString(key) },
            write: { try CredentialKeychain.writeString($0, key: key) }
        )
    }
}

extension AccessKeyStatus {
    init(_ status: CredentialStatus) {
        switch status {
        case .loading: self = .loading
        case .saving: self = .saving
        case .configured: self = .configured
        case .missing: self = .notConfigured
        case .unavailable(let message): self = .unavailable(message)
        case .saveFailed(let message): self = .saveFailed(message)
        }
    }
}

extension VoiceSignatureStore {
    func saveAccessKey(_ key: String) { credentials.accessKey.save(key) }
    func loadAccessKey() -> String? { credentials.accessKey.value }
    func deleteAccessKey() { credentials.accessKey.save(nil) }
    var hasAccessKey: Bool { credentials.accessKey.value != nil }

    func saveDeepgramApiKey(_ key: String) { credentials.deepgramKey.save(key) }
    func loadDeepgramApiKey() -> String? { credentials.deepgramKey.value }
    func deleteDeepgramApiKey() { credentials.deepgramKey.save(nil) }
    var deepgramCredentialStatus: CredentialStatus { credentials.deepgramKey.status }
    var hasDeepgramApiKey: Bool { credentials.deepgramKey.value != nil }

    func saveProfile(_ data: Data) -> Bool { credentials.saveProfile(data) }
    func loadProfile() -> Data? { credentials.profile.value }
    @discardableResult func deleteProfile() -> Bool { credentials.saveProfile(nil) }
    var hasProfile: Bool { credentials.profile.value != nil }
    func reloadCredentials() { credentials.reload() }

    var credentialsAreLoading: Bool {
        [credentials.accessKey.status, credentials.deepgramKey.status, credentials.profile.status]
            .contains(.loading)
    }

    var credentialLoadMessage: String? {
        let statuses = [credentials.deepgramKey.status, credentials.accessKey.status, credentials.profile.status]
        for status in statuses {
            if case .unavailable = status { return status.message }
        }
        return credentialsAreLoading ? "Loading voice credentials. Try again when loading finishes." : nil
    }
}
