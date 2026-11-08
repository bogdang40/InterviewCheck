import AVFoundation

/// Pure static audio sample helpers shared by the capture pipeline.
///
/// Promoted verbatim from byte-identical private copies that previously lived
/// in UnifiedAudioMixer, SeparateStreamAudioRouter, and AudioCaptureService.
enum AudioSampleConverter {

    /// Convert float32 AVAudioPCMBuffer to Int16 (PCM16) Data
    static func convertToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Convert float [-1.0, 1.0] to Int16
        var int16Data = [Int16](repeating: 0, count: frameLength)
        let samples = floatData[0]  // First channel (mono)

        for i in 0..<frameLength {
            let clamped = max(-1.0, min(1.0, samples[i]))
            int16Data[i] = Int16(clamped * Float(Int16.max))
        }

        return Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
    }

    static func isAudioUnitInitializationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code != -10875 { return false }
        return nsError.domain == "com.apple.coreaudio.avfaudio" || nsError.domain == NSOSStatusErrorDomain
    }
}
