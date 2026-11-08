import AVFoundation
import Foundation

/// Converts any AVAudioPCMBuffer to mono PCM16 at Eagle's sample rate,
/// then yields fixed-size frames suitable for Eagle processing.
final class PCM16ResamplerAndFramer {

    // MARK: - Configuration

    private let targetSampleRate: Double
    private let frameSize: Int
    let source: AudioSource

    // MARK: - State

    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var sampleBuffer: [Int16] = []
    private var currentInputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var totalSamplesEmitted: Int64 = 0

    // MARK: - Callback

    /// Callback invoked when a complete frame is ready
    /// - Parameters:
    ///   - frame: Exactly `frameSize` PCM16 samples
    ///   - timestamp: Monotonic time offset from stream start (seconds)
    var onFrameReady: ((_ frame: [Int16], _ timestamp: TimeInterval) -> Void)?

    // MARK: - Initialization

    init(source: AudioSource, frameSize: Int = EagleBindings.frameLength,
         sampleRate: Double = Double(EagleBindings.sampleRate)) {
        precondition(frameSize > 0 && sampleRate > 0)
        self.source = source
        self.targetSampleRate = sampleRate
        self.frameSize = frameSize

        // Create target format: mono, PCM16, interleaved, Eagle sample rate
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!

        // Pre-allocate buffer capacity
        sampleBuffer.reserveCapacity(frameSize * 4)
    }

    // MARK: - Public Interface

    /// Reset state for a new stream/session
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        sampleBuffer.removeAll(keepingCapacity: true)
        converter = nil
        currentInputFormat = nil
        totalSamplesEmitted = 0
    }

    /// Process an incoming audio buffer
    /// - Parameters:
    ///   - buffer: Audio from AudioCaptureService (any format)
    ///   - hostTime: The host time of buffer capture (mach_absolute_time)
    func process(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock()
        _ = hostTime

        // Check if we need to recreate the converter (format changed)
        if currentInputFormat != buffer.format {
            currentInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        }

        guard let converter = converter else {
            lock.unlock()
            return
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 16)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            lock.unlock()
            return
        }

        // Convert to target format
        var error: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else {
            lock.unlock()
            return
        }

        // Extract PCM16 samples and append to buffer
        if let int16Data = outputBuffer.int16ChannelData {
            let samples = Array(UnsafeBufferPointer(
                start: int16Data[0],
                count: Int(outputBuffer.frameLength)
            ))
            sampleBuffer.append(contentsOf: samples)
        }

        lock.unlock()

        // Emit complete frames (outside lock)
        emitFrames()
    }

    // MARK: - Private Methods
    private func emitFrames() {
        lock.lock()

        while sampleBuffer.count >= frameSize {
            let frame = Array(sampleBuffer.prefix(frameSize))
            sampleBuffer.removeFirst(frameSize)
            let timestamp = TimeInterval(totalSamplesEmitted) / targetSampleRate
            totalSamplesEmitted += Int64(frameSize)

            lock.unlock()

            // Emit frame (callback may do work, don't hold lock)
            onFrameReady?(frame, timestamp)

            lock.lock()
        }

        lock.unlock()
    }

    // MARK: - Debug

    #if DEBUG
    var bufferedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleBuffer.count
    }
    #endif
}
