import AVFoundation
import CoreMedia
import Foundation

struct SystemAudioBufferMetrics {
    let sourceSampleRate: Double
    let sourceChannels: AVAudioChannelCount
    let frameLength: AVAudioFrameCount
    let rmsDb: Double
    let conversionPath: String
}

// MARK: - Separate Stream Audio Router

/// Routes microphone and system audio to separate Deepgram streams without mixing.
///
/// Each audio source is converted to PCM16 format and sent to the appropriate
/// DualStreamDeepgramService endpoint, maintaining source separation for
/// deterministic speaker identification.
///
/// - Microphone audio → `sendMicAudio()` → Always "me"
/// - System audio → `sendSystemAudio()` → Deepgram diarization
final class SeparateStreamAudioRouter {

    // MARK: - Configuration

    enum Config {
        static let sampleRate: Double = 48000
        static let channels: AVAudioChannelCount = 1
    }

    // MARK: - Dependencies

    weak var dualStreamService: DualStreamDeepgramService?

    // MARK: - Audio Format

    /// Target format for Deepgram (48kHz, mono, float32 intermediate)
    let targetFormat: AVAudioFormat

    // MARK: - Converters

    /// Converter for microphone audio (cached, recreated on format change)
    var micConverter: AVAudioConverter?
    var lastMicFormat: AVAudioFormat?

    /// Converter for system audio
    var systemConverter: AVAudioConverter?
    var lastSystemFormat: AVAudioFormat?

    // MARK: - Thread Safety

    let processingQueue = DispatchQueue(
        label: "SeparateStreamAudioRouter.Processing",
        qos: .userInitiated
    )

    let lock = NSLock()

    // MARK: - State

    var isActive = false
    var consecutiveEmptyResampleCount = 0
    var didLogRepeatedEmptyResample = false

    /// Indicates if the router was successfully initialized and ready to use
    var isReady = false

    var onSystemAudioMetrics: ((SystemAudioBufferMetrics) -> Void)?
    var onSystemAudioConversionFailure: ((String) -> Void)?

    // MARK: - Initialization

    init(dualStreamService: DualStreamDeepgramService) {
        self.dualStreamService = dualStreamService

        // Create target format: 48kHz, mono, float32
        // Safely handle format creation failure
        if let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.sampleRate,
            channels: Config.channels,
            interleaved: false
        ) {
            self.targetFormat = format
            self.isReady = true
        } else {
            // Initialize with a fallback format (won't be used since isReady=false)
            self.targetFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            self.isReady = false
        }

        // Log after all properties initialized
        if !isReady {
            logDebug("Failed to create target audio format - audio system may be unavailable")
        }
    }

    // MARK: - Public Interface

    /// Start routing audio
    /// - Returns: true if started successfully, false if router is not ready
    @discardableResult
    func start() -> Bool {
        guard isReady else {
            logDebug("Cannot start - router not ready")
            return false
        }
        lock.lock()
        isActive = true
        lock.unlock()
        logDebug("Started")
        return true
    }

    /// Stop routing audio
    func stop() {
        lock.lock()
        isActive = false
        micConverter = nil
        systemConverter = nil
        lastMicFormat = nil
        lastSystemFormat = nil
        consecutiveEmptyResampleCount = 0
        didLogRepeatedEmptyResample = false
        lock.unlock()
        logDebug("Stopped")
    }

    func resetSystemConversionState() {
        lock.lock()
        systemConverter = nil
        lastSystemFormat = nil
        consecutiveEmptyResampleCount = 0
        lock.unlock()
    }

    /// Route microphone audio to the mic stream
    ///
    /// - Parameter buffer: PCM buffer from AVAudioEngine input tap
    func routeMicAudio(_ buffer: AVAudioPCMBuffer) {
        guard isReady, lock.withLock({ isActive }) else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // Convert to PCM16 data
            guard let data = self.convertMicToPCM16(buffer) else {
                return
            }

            // Send to mic stream
            self.dualStreamService?.sendMicAudio(data)
        }
    }

    /// Route system audio to the system stream
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer from ScreenCaptureKit
    func routeSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isReady, lock.withLock({ isActive }) else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // Convert to PCM16 data
            guard let (data, metrics) = self.convertSystemToPCM16(sampleBuffer) else {
                return
            }
            self.onSystemAudioMetrics?(metrics)

            // Send to system stream
            self.dualStreamService?.sendSystemAudio(data)
        }
    }

    // MARK: - Microphone Conversion

    /// Convert microphone AVAudioPCMBuffer to PCM16 Data
    func convertMicToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let sourceFormat = buffer.format

        // If format changed, create new converter
        if lastMicFormat != sourceFormat {
            lock.lock()
            lastMicFormat = sourceFormat
            micConverter = createConverterIfNeeded(from: sourceFormat)
            lock.unlock()
        }

        // Convert to target format if needed
        let processBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate &&
           sourceFormat.channelCount == targetFormat.channelCount &&
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            // Already in target format
            processBuffer = buffer
        } else {
            // Need conversion
            guard let converted = resampleBuffer(buffer, from: sourceFormat, using: &micConverter) else {
                return nil
            }
            processBuffer = converted
        }

        // Convert float32 to PCM16
        return AudioSampleConverter.convertToInt16Data(processBuffer)
    }

    // MARK: - System Audio Conversion
    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[AudioRouter] \(message)")
        #endif
    }
}
