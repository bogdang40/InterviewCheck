import Foundation

/// App settings that are not the detector's own (`DetectorSettings`): API
/// keys (stored in the Keychain), the Azure deployment, the audio options
/// the capture pipeline reads, and the account server address.
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    let defaults: UserDefaults
    let keyPrefix = "memanager."
    let providerCredentials = ProviderCredentials()

    /// Bumped whenever a key or the Azure configuration changes.
    @Published private(set) var providerConfigurationVersion: Int = 0

    /// Record the call's audio (the candidate). Always on for interviews.
    @Published var captureSystemAudio: Bool {
        didSet { defaults.set(captureSystemAudio, forKey: keyPrefix + "captureSystemAudio") }
    }

    /// Use Apple's on-device speech instead of Deepgram (no word timings).
    @Published var forceAppleSpeech: Bool {
        didSet { defaults.set(forceAppleSpeech, forKey: keyPrefix + "forceAppleSpeech") }
    }

    @Published var accessServerBaseURL: String {
        didSet { defaults.set(accessServerBaseURL, forKey: keyPrefix + "accessServerBaseURL") }
    }

    /// Debug builds talk to a local server; release builds start on the
    /// pinned origin and accept only a loopback override (see AccessServerAddress).
    static let defaultAccessServerBaseURL: String = {
        #if DEBUG
        return "http://localhost:8787"
        #else
        return AccessServerAddress.releaseOrigin
        #endif
    }()

    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        captureSystemAudio = defaults.object(forKey: keyPrefix + "captureSystemAudio") as? Bool ?? true
        forceAppleSpeech = defaults.bool(forKey: keyPrefix + "forceAppleSpeech")
        accessServerBaseURL = defaults.string(forKey: keyPrefix + "accessServerBaseURL")
            ?? Self.defaultAccessServerBaseURL
    }

    func bumpProviderConfigurationVersion() {
        providerConfigurationVersion &+= 1
    }

    // MARK: - API keys

    func apiKey(for provider: AIProviderType) -> String {
        providerCredentials.value(for: provider)
    }

    func apiKeyStatus(for provider: AIProviderType) -> CredentialStatus {
        providerCredentials.status(for: provider)
    }

    func reloadProviderCredentials() { providerCredentials.reload() }

    func setApiKey(_ key: String, for provider: AIProviderType) {
        providerCredentials.save(key, for: provider)
        bumpProviderConfigurationVersion()
    }

    // MARK: - Models offered in pickers

    static func availableModels(for provider: AIProviderType) -> [String] {
        switch provider {
        case .claude:
            return ["claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .openai:
            return ["gpt-5.4", "gpt-5.2", "gpt-5", "gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
        case .azureOpenAI:
            return [] // the deployment name is typed in
        }
    }

    /// Kept for callers that list fast models separately; the same set.
    static func availableQuickAssistModels(for provider: AIProviderType) -> [String] {
        availableModels(for: provider)
    }
}
