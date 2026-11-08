import Foundation

extension SettingsManager {
    func picovoiceAccessKey() -> String {
        voiceSignatureStore.loadAccessKey() ?? ""
    }

    func setPicovoiceAccessKey(_ key: String) {
        voiceSignatureStore.saveAccessKey(key)
    }

    func voiceProfile() -> Data? {
        voiceSignatureStore.loadProfile()
    }

    func setVoiceProfile(_ data: Data) -> Bool {
        voiceSignatureStore.saveProfile(data)
    }

    @discardableResult
    func deleteVoiceProfile() -> Bool {
        voiceSignatureStore.deleteProfile()
    }

    func hasVoiceProfile() -> Bool {
        voiceSignatureStore.hasProfile
    }

    func canEnableVoiceSignature() -> Bool {
        voiceSignatureStore.canEnable
    }
}
