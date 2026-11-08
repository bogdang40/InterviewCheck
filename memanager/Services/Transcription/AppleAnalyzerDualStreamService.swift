import AVFoundation
import Foundation

/// Free, on device replacement for `DualStreamDeepgramService`.
///
/// Runs two independent SpeechAnalyzer streams (microphone and system audio)
/// and emits the same `DeepgramTranscriptSegment` DTO and combined connection
/// state shape, so `TranscriptMerger` and `AudioCaptureService` consume it
/// without changes. All callbacks are delivered on the main queue.
@available(macOS 26.0, *)
final class AppleAnalyzerDualStreamService {
    private let locale: Locale
    private let contextualStrings: [String]

    private var micTranscriber: AppleAnalyzerStreamTranscriber?
    private var systemTranscriber: AppleAnalyzerStreamTranscriber?

    private var micState: DeepgramConnectionState = .disconnected
    private var systemState: DeepgramConnectionState = .disconnected

    var onMicTranscript: ((DeepgramTranscriptSegment) -> Void)?
    var onSystemTranscript: ((DeepgramTranscriptSegment) -> Void)?
    var onConnectionStateChanged: ((DualStreamConnectionState) -> Void)?
    var onSystemAudioMetrics: ((SystemAudioBufferMetrics) -> Void)?

    init(locale: Locale, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    var isFullyConnected: Bool {
        micState.isConnected && systemState.isConnected
    }

    func start() {
        let mic = makeTranscriber(source: .microphone)
        mic.onSegment = { [weak self] segment in
            self?.onMicTranscript?(segment)
        }
        mic.onStateChange = { [weak self] state in
            self?.micState = state
            self?.publishConnectionState()
        }
        micTranscriber = mic
        mic.start()

        startSystemTranscriber()
    }

    func stop() {
        micTranscriber?.stop()
        micTranscriber = nil
        systemTranscriber?.stop()
        systemTranscriber = nil
    }

    /// Recreates only the system stream; used by the stall watchdog.
    func restartSystemStream() {
        systemTranscriber?.stop()
        systemTranscriber = nil
        startSystemTranscriber()
    }

    func ingestMicBuffer(_ buffer: AVAudioPCMBuffer) {
        micTranscriber?.ingest(buffer)
    }

    func ingestSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        let metrics = SystemAudioBufferMetrics(
            sourceSampleRate: buffer.format.sampleRate,
            sourceChannels: buffer.format.channelCount,
            frameLength: buffer.frameLength,
            rmsDb: Self.rmsDecibels(buffer),
            conversionPath: "apple_analyzer"
        )
        onSystemAudioMetrics?(metrics)
        systemTranscriber?.ingest(buffer)
    }

    private func startSystemTranscriber() {
        let system = makeTranscriber(source: .systemAudio)
        system.onSegment = { [weak self] segment in
            self?.onSystemTranscript?(segment)
        }
        system.onStateChange = { [weak self] state in
            self?.systemState = state
            self?.publishConnectionState()
        }
        systemTranscriber = system
        system.start()
    }

    private func makeTranscriber(source: AudioSource) -> AppleAnalyzerStreamTranscriber {
        AppleAnalyzerStreamTranscriber(
            source: source,
            locale: locale,
            contextualStrings: contextualStrings
        )
    }

    private func publishConnectionState() {
        onConnectionStateChanged?(
            DualStreamConnectionState(mic: micState, system: systemState)
        )
    }

    /// RMS level of the first channel in decibels, supporting the float32 and
    /// int16 layouts ScreenCaptureKit and the converters produce.
    static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }

        var sumOfSquares = 0.0
        if let floatData = buffer.floatChannelData {
            let samples = floatData[0]
            for index in 0..<frames {
                let sample = Double(samples[index])
                sumOfSquares += sample * sample
            }
        } else if let intData = buffer.int16ChannelData {
            let samples = intData[0]
            for index in 0..<frames {
                let sample = Double(samples[index]) / Double(Int16.max)
                sumOfSquares += sample * sample
            }
        } else {
            return -160
        }

        let rms = (sumOfSquares / Double(frames)).squareRoot()
        guard rms > 0 else { return -160 }
        return max(-160, 20 * log10(rms))
    }
}
