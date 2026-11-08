import AVFoundation
import AudioToolbox
import CoreMedia
import Combine
import os.log

enum UnifiedAudioMixerError: LocalizedError {
    case noInputDevice
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available"
        case .invalidInputFormat(let sampleRate, let channels):
            return "Invalid input format (rate: \(sampleRate), channels: \(channels))"
        }
    }
}

/// Mixes microphone and system audio into a single 48kHz mono PCM16 stream.
///
/// Uses AVAudioMixerNode to combine:
/// - Microphone input via AVAudioEngine.inputNode
/// - System audio via AVAudioPlayerNode (injected from ScreenCaptureKit)
///
/// Output is continuous PCM16 data suitable for Deepgram transcription.
final class UnifiedAudioMixer: ObservableObject {

    // MARK: - Configuration

    enum Config {
        static let sampleRate: Double = 48000
        static let channels: AVAudioChannelCount = 1
        static let bufferSize: AVAudioFrameCount = 1024
        static let maxEffectiveGain: Float = 2.0
        static let autoBalanceUpdateInterval: TimeInterval = 0.6
        static let autoBalanceThresholdDb: Float = 9.0
        static let autoBalanceStepDb: Float = 0.5
        static let autoBalanceMinMultiplier: Float = 0.5
        static let autoBalanceMaxMultiplier: Float = 2.0
        static let autoBalanceMinActiveRms: Float = 0.01
    }

    // MARK: - Release Logging
    static let audioLogger = OSLog(subsystem: "com.InterviewCheck.app", category: "UnifiedMixer")

    // MARK: - Audio Engine Components

    var audioEngine = AVAudioEngine()
    let engineConfigurationObserver = EngineConfigurationObserver()
    let mixerNode = AVAudioMixerNode()
    let micGainNode = AVAudioMixerNode()
    let isolationMixer = AVAudioMixerNode()  // Format isolation from hardware
    let systemAudioPlayerNode = AVAudioPlayerNode()
    let keepAliveNode = AVAudioPlayerNode()
    var mixerTapInstalled = false
    var micTapInstalled = false

    // MARK: - Output Format

    /// Target format for mixed output (48kHz, mono, float32)
    let mixerOutputFormat: AVAudioFormat

    /// Converter for resampling system audio to mixer format
    var systemAudioConverter: AVAudioConverter?

    /// Dedicated converter for mic tap output conversion (isolated from system audio path)
    var micConverter: AVAudioConverter?

    // MARK: - State

    @Published var isActive = false
    @Published var lastError: String?
    var hasAttachedNodes = false
    var baseMicGain: Float = 1.0
    var baseSystemGain: Float = 1.0
    var autoMicMultiplier: Float = 1.0
    var autoSystemMultiplier: Float = 1.0
    var autoBalanceEnabled: Bool = false

    var micRmsPostGain: Float = 0.0
    var systemRmsPostGain: Float = 0.0
    var lastMicLevelTime: TimeInterval = 0
    var lastSystemLevelTime: TimeInterval = 0
    var lastAutoBalanceTime: TimeInterval = 0
    var conversionErrorCount = 0

    // MARK: - Debug Mode (NDJSON)
    let ndjsonRunId = "run1"
    var lastNDJSONMixedRmsLogTime: TimeInterval = 0
    var mixedSilentStreak: Int = 0

    // MARK: - HFP Format Transition Handling
    // Tracks input sample rate to detect Bluetooth HFP mode switches (48kHz -> 16kHz)
    var lastSeenInputSampleRate: Double = 0
    var consecutiveConversionFailures = 0
    let conversionFailureThreshold = 50
    var keepAliveBuffer: AVAudioPCMBuffer?

    // MARK: - Callbacks

    /// Called with mixed PCM16 audio data ready for Deepgram
    var onMixedAudio: ((Data) -> Void)?
    /// Called when microphone input buffers arrive (used for mic activity checks)
    var onMicBuffer: (() -> Void)?
    /// Called when audio engine configuration changes (device routing change mid-session)
    var onConfigurationChange: (() -> Void)?

    // MARK: - Thread Safety

    let processingQueue = DispatchQueue(
        label: "UnifiedAudioMixer.Processing",
        qos: .userInitiated
    )

    // MARK: - Initialization

    init() {
        // Create output format: 48kHz, mono, float32
        mixerOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.sampleRate,
            channels: Config.channels,
            interleaved: false
        )!
    }

    deinit {
        stop()
    }

    func removeMixerTapIfNeeded() {
        guard mixerTapInstalled else { return }
        mixerNode.removeTap(onBus: 0)
        mixerTapInstalled = false
    }

    func removeMicTapIfNeeded() {
        guard micTapInstalled else { return }
        micGainNode.removeTap(onBus: 0)
        micTapInstalled = false
    }

    func effectiveMicGain() -> Float {
        let auto = autoBalanceEnabled ? autoMicMultiplier : 1.0
        return min(Config.maxEffectiveGain, max(0.0, baseMicGain * auto))
    }

    func effectiveSystemGain() -> Float {
        let auto = autoBalanceEnabled ? autoSystemMultiplier : 1.0
        return min(Config.maxEffectiveGain, max(0.0, baseSystemGain * auto))
    }

    func applyGains() {
        micGainNode.outputVolume = effectiveMicGain()
        systemAudioPlayerNode.volume = effectiveSystemGain()
    }

    // MARK: - Public Interface

    func setBaseMicGain(_ gain: Float) {
        baseMicGain = min(Config.maxEffectiveGain, max(0.0, gain))
        applyGains()
    }

    func setBaseSystemGain(_ gain: Float) {
        baseSystemGain = min(Config.maxEffectiveGain, max(0.0, gain))
        applyGains()
    }

    func setAutoBalanceEnabled(_ enabled: Bool) {
        autoBalanceEnabled = enabled
        if !enabled {
            autoMicMultiplier = 1.0
            autoSystemMultiplier = 1.0
        }
        applyGains()
    }

    /// Start the unified audio mixer
    func start() throws {
        try startInternal(allowRetry: true)
    }

    /// Stop the unified audio mixer
    func stop() {
        guard isActive || mixerTapInstalled || micTapInstalled || hasAttachedNodes else { return }

        removeMixerTapIfNeeded()
        removeMicTapIfNeeded()
        systemAudioPlayerNode.stop()
        keepAliveNode.stop()
        keepAliveBuffer = nil

        // Remove configuration change observer before stopping engine
        engineConfigurationObserver.detach()

        audioEngine.stop()

        // Reset converters and HFP state
        micConverter = nil
        lastSeenInputSampleRate = 0
        consecutiveConversionFailures = 0

        if hasAttachedNodes {
            audioEngine.detach(mixerNode)
            audioEngine.detach(micGainNode)
            audioEngine.detach(isolationMixer)  // PHASE 6
            audioEngine.detach(systemAudioPlayerNode)
            audioEngine.detach(keepAliveNode)
            hasAttachedNodes = false
        }

        isActive = false
        logDebug("Stopped")
    }

    func startKeepAliveIfNeeded(force: Bool = false) {
        if !force {
            guard let outputID = AudioDeviceManager.resolvedOutputDeviceID(),
                  AudioDeviceManager.isBluetooth(outputID) else {
                return
            }
        }

        if keepAliveBuffer == nil {
            let frameCount = AVAudioFrameCount(mixerOutputFormat.sampleRate / 100)  // 10ms buffer
            guard let buffer = AVAudioPCMBuffer(pcmFormat: mixerOutputFormat, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            if let floatData = buffer.floatChannelData {
                let samples = floatData[0]
                for i in 0..<Int(frameCount) {
                    samples[i] = 0
                }
            }
            keepAliveBuffer = buffer
        }

        guard let buffer = keepAliveBuffer else { return }
        if keepAliveNode.isPlaying {
            return
        }
        keepAliveNode.volume = 0
        keepAliveNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        keepAliveNode.play()
        logDebug("Keep-alive loop started")
    }

    /// Restart mixer after input device changes
    func restartForDeviceChange() throws {
        if isActive {
            stop()
        }
        try start()
    }

    /// Inject system audio from ScreenCaptureKit
    ///
    /// Converts CMSampleBuffer to AVAudioPCMBuffer and schedules it for mixing.
    func injectSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isActive else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // Convert to PCM buffer in mixer format
            guard let pcmBuffer = self.convertToPCMBuffer(sampleBuffer) else {
                return
            }

            self.noteSystemLevel(pcmBuffer)

            if !self.systemAudioPlayerNode.isPlaying {
                self.systemAudioPlayerNode.play()
            }

            // Schedule buffer on player node for mixing
            self.systemAudioPlayerNode.scheduleBuffer(pcmBuffer)
        }
    }

    // Intentionally no tap reinstall while running; avoid NSException on tap install.

    // MARK: - Engine Configuration Change Handling

    /// Handle audio engine configuration changes (device routing changes mid-session)
    func handleEngineConfigurationChange() {
        logDebug("Audio engine configuration changed - device routing may have changed")
        // Notify the service to trigger restart via debounced reconfigure
        onConfigurationChange?()
    }

    // MARK: - Audio Unit Configuration

    /// Configure maximum frames per slice for an audio unit.
    /// Required for Bluetooth devices which may use larger buffer sizes (e.g., 513 frames).
    /// Default value of 512 is insufficient for Bluetooth HFP audio.
    func configureMaxFramesPerSlice(_ audioUnit: AudioUnit, maxFrames: UInt32 = 4096) {
        var maxFramesPerSlice = maxFrames
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFramesPerSlice,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status == noErr {
            logDebug("Set maxFramesPerSlice to \(maxFrames)")
        } else {
            logDebug("Warning: Failed to set maxFramesPerSlice (status: \(status))")
        }
    }

    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[UnifiedMixer] \(message)")
        #endif
    }
}
