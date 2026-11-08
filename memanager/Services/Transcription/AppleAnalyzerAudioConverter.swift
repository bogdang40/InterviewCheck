import AVFoundation

/// Converts arbitrary PCM buffers (mic hardware format, ScreenCaptureKit system
/// audio) into the single audio format the speech analyzer asked for.
///
/// One instance serves exactly one stream and must be fed from one thread at a
/// time; the underlying `AVAudioConverter` keeps resampler state across calls so
/// stream continuity is preserved at buffer boundaries.
final class AppleAnalyzerAudioConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var currentSourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let sourceFormat = buffer.format
        if sourceFormat == targetFormat {
            return buffer
        }

        if converter == nil || currentSourceFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            currentSourceFormat = sourceFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
