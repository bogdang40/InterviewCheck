import Foundation
import Combine

// MARK: - AccessKey Status

enum AccessKeyStatus: Equatable {
    case loading
    case saving
    case unavailable(String)
    case notConfigured
    case configured
    case saveFailed(String)

    var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }
}

// MARK: - Speaker Identification Mode

enum SpeakerIdentificationMode: String, Codable, CaseIterable {
    case manual
    case auto

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .auto: return "Auto"
        }
    }
}

/// Manages storage of voice signature data (AccessKey, profile, settings)
final class VoiceSignatureStore: ObservableObject {

    // MARK: - Singleton

    static let shared = VoiceSignatureStore()

    let credentials = VoiceCredentials()

    // MARK: - UserDefaults Keys

    private let enabledKey = "memanager.voiceSignature.enabled"
    private let thresholdEnterKey = "memanager.voiceSignature.thresholdEnter"
    private let thresholdExitKey = "memanager.voiceSignature.thresholdExit"
    private let sourceBasedKey = "memanager.speaker.sourceBased"
    private let speakerIdModeKey = "memanager.speaker.identificationMode"
    private let legacyMicGainKey = "memanager.speaker.legacyMicGain"
    private let legacySystemGainKey = "memanager.speaker.legacySystemGain"
    private let legacyAutoBalanceKey = "memanager.speaker.legacyAutoBalance"
    private let echoFilterEnabledKey = "memanager.speaker.echoFilterEnabled"
    private let echoFilterThresholdKey = "memanager.speaker.echoFilterThreshold"
    private let echoFilterTimeWindowKey = "memanager.speaker.echoFilterTimeWindow"

    // MARK: - Properties

    private let defaults = AppDefaults.standard

    /// Reactive indicator for UI binding - updated after Keychain operations
    @Published private(set) var accessKeyStatus: AccessKeyStatus = .loading
    @Published private(set) var deepgramApiKeyStatus: AccessKeyStatus = .loading
    @Published private(set) var profileStatus: CredentialStatus = .loading

    /// Path to bundled Eagle model file
    var modelPath: String {
        Bundle.main.path(forResource: "eagle_params", ofType: "pv") ?? ""
    }

    // MARK: - Initialization

    private init() {
        // Load values from UserDefaults, falling back to defaults
        let savedEnabled = defaults.bool(forKey: enabledKey)
        let savedEnterThreshold = defaults.float(forKey: thresholdEnterKey)
        let savedExitThreshold = defaults.float(forKey: thresholdExitKey)

        self.isEnabled = savedEnabled
        self.thresholdEnterMe = savedEnterThreshold > 0 ? savedEnterThreshold : 0.85
        self.thresholdExitMe = savedExitThreshold > 0 ? savedExitThreshold : 0.75

        // Source-based identification defaults to true for new installs
        // Check if key exists to differentiate new vs existing users
        if defaults.object(forKey: sourceBasedKey) != nil {
            self.useSourceBasedIdentification = defaults.bool(forKey: sourceBasedKey)
        } else {
            // New install - default to source-based mode
            self.useSourceBasedIdentification = true
        }

        if let savedMode = defaults.string(forKey: speakerIdModeKey),
           let mode = SpeakerIdentificationMode(rawValue: savedMode) {
            self.speakerIdentificationMode = mode
        } else {
            self.speakerIdentificationMode = .manual
        }

        if defaults.object(forKey: legacyMicGainKey) != nil {
            self.legacyMicGain = max(0.0, min(2.0, defaults.float(forKey: legacyMicGainKey)))
        } else {
            self.legacyMicGain = 1.0
        }

        if defaults.object(forKey: legacySystemGainKey) != nil {
            self.legacySystemGain = max(0.0, min(2.0, defaults.float(forKey: legacySystemGainKey)))
        } else {
            self.legacySystemGain = 1.0
        }

        if defaults.object(forKey: legacyAutoBalanceKey) != nil {
            self.legacyAutoBalanceEnabled = defaults.bool(forKey: legacyAutoBalanceKey)
        } else {
            self.legacyAutoBalanceEnabled = true
        }
        
        // Echo filter settings - default to enabled for cleaner transcripts
        if defaults.object(forKey: echoFilterEnabledKey) != nil {
            self.echoFilterEnabled = defaults.bool(forKey: echoFilterEnabledKey)
        } else {
            self.echoFilterEnabled = true  // Default enabled
        }
        
        if defaults.object(forKey: echoFilterThresholdKey) != nil {
            self.echoFilterThreshold = max(0.3, min(0.95, defaults.double(forKey: echoFilterThresholdKey)))
        } else {
            self.echoFilterThreshold = 0.6  // Default 60% similarity
        }
        
        if defaults.object(forKey: echoFilterTimeWindowKey) != nil {
            self.echoFilterTimeWindow = max(0.5, min(5.0, defaults.double(forKey: echoFilterTimeWindowKey)))
        } else {
            self.echoFilterTimeWindow = 3.0  // Default 3 seconds
        }

        credentials.onChange = { [weak self] in self?.refreshCredentialStatus() }
        credentials.reload()
    }

    private func refreshCredentialStatus() {
        accessKeyStatus = AccessKeyStatus(credentials.accessKey.status)
        deepgramApiKeyStatus = AccessKeyStatus(credentials.deepgramKey.status)
        profileStatus = credentials.profile.status
    }

    // MARK: - Settings (UserDefaults with Published wrappers)

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: enabledKey) }
    }

    @Published var thresholdEnterMe: Float {
        didSet { defaults.set(thresholdEnterMe, forKey: thresholdEnterKey) }
    }

    @Published var thresholdExitMe: Float {
        didSet { defaults.set(thresholdExitMe, forKey: thresholdExitKey) }
    }

    // MARK: - Source-Based Speaker Identification

    /// When true, uses audio source for speaker identification:
    /// - Microphone audio = "me"
    /// - System audio = numbered speakers via Deepgram diarization
    ///
    /// When false, uses legacy unified stream with acoustic diarization.
    @Published var useSourceBasedIdentification: Bool {
        didSet { defaults.set(useSourceBasedIdentification, forKey: sourceBasedKey) }
    }

    // MARK: - Speaker Identification Mode (Legacy Stream)

    /// Controls how "me" is identified when using legacy unified diarization.
    /// - manual: user marks speakers (tap/hotkey)
    /// - auto: uses voice signature to auto-mark the current diarized speaker as "me"
    @Published var speakerIdentificationMode: SpeakerIdentificationMode {
        didSet { defaults.set(speakerIdentificationMode.rawValue, forKey: speakerIdModeKey) }
    }

    // MARK: - Legacy Mix Balance (Unified Stream)

    /// Base gain applied to microphone input in legacy mixed mode.
    @Published var legacyMicGain: Float {
        didSet {
            let clamped = max(0.0, min(2.0, legacyMicGain))
            if clamped != legacyMicGain {
                legacyMicGain = clamped
                return
            }
            defaults.set(legacyMicGain, forKey: legacyMicGainKey)
        }
    }

    /// Base gain applied to system audio input in legacy mixed mode.
    @Published var legacySystemGain: Float {
        didSet {
            let clamped = max(0.0, min(2.0, legacySystemGain))
            if clamped != legacySystemGain {
                legacySystemGain = clamped
                return
            }
            defaults.set(legacySystemGain, forKey: legacySystemGainKey)
        }
    }

    /// When enabled, auto-balances mic vs system contributions (bounded, slow).
    @Published var legacyAutoBalanceEnabled: Bool {
        didSet { defaults.set(legacyAutoBalanceEnabled, forKey: legacyAutoBalanceKey) }
    }
    
    // MARK: - Echo Filter Settings (Source-Based Mode)
    
    /// When enabled, filters duplicate transcripts caused by echo between mic and speakers.
    /// - Mic picking up speaker playback (other person's audio from speakers)
    /// - System audio picking up room echo (user's voice reverberating)
    @Published var echoFilterEnabled: Bool {
        didSet { defaults.set(echoFilterEnabled, forKey: echoFilterEnabledKey) }
    }
    
    /// Minimum word similarity ratio (0.0-1.0) to consider as duplicate.
    /// Higher values = stricter matching (fewer false positives, may miss some echoes)
    /// Lower values = looser matching (catches more echoes, may have false positives)
    /// Default: 0.6 (60% word overlap)
    @Published var echoFilterThreshold: Double {
        didSet {
            let clamped = max(0.3, min(0.95, echoFilterThreshold))
            if clamped != echoFilterThreshold {
                echoFilterThreshold = clamped
                return
            }
            defaults.set(echoFilterThreshold, forKey: echoFilterThresholdKey)
        }
    }
    
    /// Time window in seconds for considering segments as potential duplicates.
    /// Larger windows catch more delayed echoes but may cause false positives.
    /// Default: 3.0 seconds
    @Published var echoFilterTimeWindow: Double {
        didSet {
            let clamped = max(0.5, min(5.0, echoFilterTimeWindow))
            if clamped != echoFilterTimeWindow {
                echoFilterTimeWindow = clamped
                return
            }
            defaults.set(echoFilterTimeWindow, forKey: echoFilterTimeWindowKey)
        }
    }

    var isAutoSpeakerIdentificationEnabled: Bool {
        speakerIdentificationMode == .auto
    }

    func toggleSpeakerIdentificationMode() {
        speakerIdentificationMode = speakerIdentificationMode == .manual ? .auto : .manual
    }

    // MARK: - Bulk Operations

    /// Delete all voice signature data
    func deleteAll() {
        deleteAccessKey()
        deleteProfile()
        deleteDeepgramApiKey()
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: thresholdEnterKey)
        defaults.removeObject(forKey: thresholdExitKey)
        defaults.removeObject(forKey: speakerIdModeKey)
    }

    /// Check if voice signature can be enabled (has both AccessKey and profile)
    var canEnable: Bool {
        hasAccessKey && hasProfile
    }
}
