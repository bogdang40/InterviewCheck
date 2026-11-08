import AVFoundation
import Foundation

enum MicrophoneTapError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone available."
        }
    }
}

/// Owns an audio engine with one tap on the input node. Shared by the
/// enrollment wizard and the live test so neither carries engine plumbing.
final class MicrophoneTap {
    private var engine: AVAudioEngine?

    var isRunning: Bool { engine != nil }

    func start(bufferSize: AVAudioFrameCount = 1024, handler: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneTapError.noInput
        }
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer, mach_absolute_time())
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    /// Root mean square level of the first channel, scaled to 0...1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = floatData[0]
        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = samples[index]
            sum += sample * sample
        }
        return min(sqrt(sum / Float(frameLength)) * 2.0, 1.0)
    }
}
