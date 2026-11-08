import AVFoundation
import Combine
import Speech
import AppKit
import CoreMedia
import CoreAudio

// MARK: - Audio Capture Service

/// Captures microphone audio using AVAudioEngine and transcribes using SFSpeechRecognizer.
/// Uses standard Microphone permission (reliable approach).
final class AudioCaptureService: ObservableObject {
    static let shared = AudioCaptureService()

    var restoredSessionTranscript: RestoredSessionTranscript?

    @Published var isRecording = false
    @Published var isEngineRunning = false
    @Published var transcript = ""
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var partialMe: String = ""
    @Published var partialOther: String = ""
    @Published var partialOtherSpeaker: TranscriptSpeaker = .speaker(0)
    @Published var legacySpeakerCount: Int = 0
    @Published var legacyLastSpeakerId: Int?
    @Published var legacyDiarizationLabelsSeen: Bool = false
    @Published var legacyDiarizationLastLabelTime: Date?
    @Published var errorMessage: String?
    @Published var transcriptionError: TranscriptionError?
    @Published var isSystemAudioActive = false
    @Published var systemAudioHealth = SystemAudioHealthSnapshot()

    @Published var micBufferCount = 0
    @Published var systemBufferCount = 0
    @Published var mixedBufferCount = 0
    @Published var micBufferLastTime: Date?
    @Published var systemBufferLastTime: Date?
    @Published var mixedBufferLastTime: Date?
    @Published var deepgramLegacyState: DeepgramConnectionState = .disconnected
    @Published var deepgramMicState: DeepgramConnectionState = .disconnected
    @Published var deepgramSystemState: DeepgramConnectionState = .disconnected

    // Voice Signature State (for UI)
    @Published var isVoiceSignatureActive = false
    @Published var currentSpeakerLabel: SpeakerLabel = .unknown
    @Published var currentVoiceScore: Float = 0.0

    // MARK: - Capture State

    var activeTranscriptionMode: TranscriptionMode = .appleSpeech

    @Published var captureState: CaptureState = .idle
    @Published var startPhase: StartPhase = .idle
    @Published var desiredState: DesiredCaptureState = .idle
    var transitionTask: Task<Void, Never>?
    var stateMachineDirty = false
    var pendingStartReason: StartReason = .newSession
    var shouldClearTranscriptOnStop = false

    var audioEngine = AVAudioEngine()
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?
    let speechRecognizer: SFSpeechRecognizer?
    let systemSpeechRecognizer: SFSpeechRecognizer?
    var systemRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var systemRecognitionTask: SFSpeechRecognitionTask?
    let systemAudioCapture = SystemAudioCaptureService()
    let settings = SettingsManager.shared

    // MARK: - Voice Signature Integration

    let voiceSignatureStore = VoiceSignatureStore.shared
    var voiceSignatureService: VoiceSignatureRecognitionService?
    var transcriptionLabeler: TranscriptionLabeler?
    var cancellables = Set<AnyCancellable>()

    // MARK: - Deepgram Integration (Unified Stream - Legacy Mode)

    var deepgramService: DeepgramService?
    var unifiedAudioMixer: UnifiedAudioMixer?
    @Published var isDeepgramActive = false
    let speakerMapper = DeepgramSpeakerMapper()

    // MARK: - Source-Based Speaker Identification (New Mode)

    var dualStreamService: DualStreamDeepgramService?
    var audioRouter: SeparateStreamAudioRouter?
    var transcriptMerger: TranscriptMerger?

    // MARK: - Apple Analyzer (free on device engine, macOS 26+)

    /// Type erased storage for `AppleAnalyzerDualStreamService`; extensions
    /// cannot add stored properties and availability gated stored types are
    /// not expressible, so the gated accessor lives in the wiring extension.
    var appleAnalyzerBox: AnyObject?
    @Published var isAppleAnalyzerActive = false

    /// Whether to use source-based speaker identification
    /// (microphone = "me", system audio = diarized speakers)
    var useSourceBasedIdentification: Bool {
        voiceSignatureStore.useSourceBasedIdentification
    }

    /// Track stream start time for transcript alignment
    var micStreamStartTime: TimeInterval = 0
    var systemStreamStartTime: TimeInterval = 0
    var micTranscriptStartDate: Date?
    var systemTranscriptStartDate: Date?

    /// Capture generation token to ignore stale callbacks
    let captureTokenLock = NSLock()
    var captureToken: UInt64 = 0

    /// Guards against race conditions when starting capture
    var isStartingCapture = false

    let recordingStateLock = NSLock()
    var isRecordingFlag = false

    /// Tracks whether we've logged the system audio format (to avoid log spam)
    var hasLoggedAudioFormat = false
    var isInputTapInstalled = false
    var partialMeDeepgramId: Int?
    var partialOtherDeepgramId: Int?
    var systemAudioStartToken: UInt64 = 0
    var systemAudioStartTask: Task<Void, Never>?
    var systemHealthWatchdogTimer: Timer?
    var lastSystemAudibleAt: Date?
    var lastSystemReconnectAttemptAt: Date?
    var systemReconnectAttempts: [Date] = []
    let silenceThresholdDb: Double = -55
    let noTranscriptTimeout: TimeInterval = 8
    let reconnectBackoff: TimeInterval = 2
    let maxReconnectAttempts: Int = 2
    let reconnectWindow: TimeInterval = 60
    var isMonitoringInputDevices = false
    var lastResolvedInputDeviceID: AudioDeviceID?
    var lastResolvedOutputDeviceID: AudioDeviceID?
    var inputDeviceChangeTask: Task<Void, Never>?
    var isReconfiguringInputDevice = false
    var lastSourceBasedValue: Bool = false
    var sourceBasedToggleTask: Task<Void, Never>?
    var micBufferCounter = 0
    var systemBufferCounter = 0
    var mixedBufferCounter = 0
    var lastMicBufferUpdate: TimeInterval = 0
    var lastSystemBufferUpdate: TimeInterval = 0
    var lastMixedBufferUpdate: TimeInterval = 0
    var lastMicActivityTime: TimeInterval = 0
    var lastSystemActivityTime: TimeInterval = 0
    var lastMixedActivityTime: TimeInterval = 0
    let bufferUpdateInterval: TimeInterval = 0.5
    let mixedActivationTimeout: TimeInterval = 2.0
    let bufferStateLock = NSLock()
    let audioEngineQueue = DispatchQueue(label: "AudioCaptureService.Engine", qos: .userInitiated)
    let engineStartTimeout: TimeInterval = 5.0
    let unifiedEngineStartTimeout: TimeInterval = 5.0

    // MARK: - Debug Mode (NDJSON)
    let ndjsonRunId = "run1"
    var lastNDJSONHeartbeatTime: TimeInterval = 0
    var lastNDJSONMergedSyncTime: TimeInterval = 0
    var lastSystemAudioStatsLogTime: TimeInterval = 0
    var lastSystemAudioStatsRmsDb: Double = -160
    let systemAudioStatsLogInterval: TimeInterval = 0.5
    let systemAudioStatsLogRmsDelta: Double = 3.0

    /// Mutex flag shared by buffer health monitoring and timeout recovery so
    /// the two restart paths never overlap. Internal because the watchdog
    /// extension file participates in the handshake.
    var isHandlingConfigurationChange = false
    var bufferHealthTimer: Timer?

    init() {
        speechRecognizer = TestRuntime.isRunningUnitTests ? nil : SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        systemSpeechRecognizer = TestRuntime.isRunningUnitTests ? nil : SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        if speechRecognizer == nil {
            logDebug("WARNING: Speech recognizer initialization failed for en-US locale")
        }

        voiceSignatureStore.$legacyMicGain
            .sink { [weak self] gain in
                self?.unifiedAudioMixer?.setBaseMicGain(gain)
            }
            .store(in: &cancellables)

        voiceSignatureStore.$legacySystemGain
            .sink { [weak self] gain in
                self?.unifiedAudioMixer?.setBaseSystemGain(gain)
            }
            .store(in: &cancellables)

        voiceSignatureStore.$legacyAutoBalanceEnabled
            .sink { [weak self] enabled in
                self?.unifiedAudioMixer?.setAutoBalanceEnabled(enabled)
            }
            .store(in: &cancellables)

        lastSourceBasedValue = voiceSignatureStore.useSourceBasedIdentification
        voiceSignatureStore.$useSourceBasedIdentification
            .sink { [weak self] newValue in
                guard let self else { return }
                guard newValue != self.lastSourceBasedValue else { return }
                self.lastSourceBasedValue = newValue
                self.handleSourceBasedToggle(newValue)
            }
            .store(in: &cancellables)

        // Recovery relies solely on buffer timeout detection: proactive
        // configuration change handling caused restart storms during
        // Bluetooth transitions (HFP transitions take 2-5 seconds).
        logDebug("AudioCaptureService initialized (AVAudioEngine mode)")
        logDebug("Speech recognizer available: \(speechRecognizer?.isAvailable ?? false)")
        if !TestRuntime.isRunningUnitTests {
            startMonitoringInputDevices()
        }
    }

    deinit {
        stopSystemHealthWatchdog()
        if isMonitoringInputDevices {
            AudioDeviceManager.stopMonitoringInputChanges()
        }
        cleanupRecording()
        logDebug("AudioCaptureService deallocated")
    }

    func clearError() {
        errorMessage = nil
        transcriptionError = nil
    }

    func openSystemSettings() {
        guard let error = transcriptionError,
              let url = error.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Permission Checks

    func cleanupRecording(preservePartials: Bool = false) {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isStartingCapture = false

        if preservePartials {
            // Finalize partial mic transcript as an entry before clearing
            if !partialMe.isEmpty {
                let speaker = determineSpeaker(for: .microphone)
                appendTranscriptEntry(partialMe, speaker: speaker)
            }
        }

        partialMe = ""

        rebuildTranscript()
    }

    // MARK: - Error Handling

    func setError(_ error: TranscriptionError) {
        transcriptionError = error
        errorMessage = error.errorDescription
        logDebug("Error set: \(error.errorDescription ?? "unknown")")
    }

    func resetTranscriptStartTimes() {
        micStreamStartTime = 0
        systemStreamStartTime = 0
        micTranscriptStartDate = nil
        systemTranscriptStartDate = nil
    }

    func bumpCaptureToken() {
        captureTokenLock.lock()
        captureToken &+= 1
        captureTokenLock.unlock()
    }

    func currentCaptureToken() -> UInt64 {
        captureTokenLock.lock()
        let token = captureToken
        captureTokenLock.unlock()
        return token
    }

    func isCaptureTokenActive(_ token: UInt64) -> Bool {
        captureTokenLock.lock()
        let active = token == captureToken
        captureTokenLock.unlock()
        return active
    }

    func setRecordingFlag(_ value: Bool) {
        recordingStateLock.lock()
        isRecordingFlag = value
        recordingStateLock.unlock()
    }

    func isRecordingActive() -> Bool {
        recordingStateLock.lock()
        let active = isRecordingFlag
        recordingStateLock.unlock()
        return active
    }

    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[AudioCapture] \(message)")
        #endif
    }
}
