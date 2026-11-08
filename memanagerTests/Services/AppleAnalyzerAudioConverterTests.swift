import AVFoundation
import XCTest
@testable import memanager

/// Pins the format conversion behavior feeding the on device analyzer:
/// passthrough on matching formats, downmix plus resample otherwise, and
/// converter state survival across sequential buffers.
final class AppleAnalyzerAudioConverterTests: XCTestCase {
    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        value: Float = 0.25
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = value
            }
        }
        return buffer
    }

    private var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    func testMatchingFormatPassesThrough() {
        let converter = AppleAnalyzerAudioConverter(targetFormat: targetFormat)
        let buffer = makeBuffer(sampleRate: 16_000, channels: 1, frames: 320)
        let output = converter.convert(buffer)
        XCTAssertTrue(output === buffer, "Identical formats must not copy")
    }

    func testStereo48kDownmixesAndResamples() {
        let converter = AppleAnalyzerAudioConverter(targetFormat: targetFormat)
        guard let first = converter.convert(makeBuffer(sampleRate: 48_000, channels: 2, frames: 4800)) else {
            return XCTFail("Conversion produced no output")
        }
        XCTAssertEqual(first.format.sampleRate, 16_000)
        XCTAssertEqual(first.format.channelCount, 1)
        XCTAssertGreaterThan(first.frameLength, 0)

        // The resampler primes with some latency on the first buffer, so a
        // single buffer under-delivers; cumulative output across consecutive
        // buffers must track the 3:1 ratio.
        let second = converter.convert(makeBuffer(sampleRate: 48_000, channels: 2, frames: 4800))
        let total = Double(first.frameLength) + Double(second?.frameLength ?? 0)
        XCTAssertEqual(total, 3200, accuracy: 320)
    }

    func testSequentialBuffersBothConvert() {
        let converter = AppleAnalyzerAudioConverter(targetFormat: targetFormat)
        let first = converter.convert(makeBuffer(sampleRate: 44_100, channels: 2, frames: 4410))
        let second = converter.convert(makeBuffer(sampleRate: 44_100, channels: 2, frames: 4410))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second?.frameLength ?? 0, 0, "Converter state must survive across calls")
    }

    func testFormatChangeMidStreamRebuildsConverter() {
        let converter = AppleAnalyzerAudioConverter(targetFormat: targetFormat)
        XCTAssertNotNil(converter.convert(makeBuffer(sampleRate: 48_000, channels: 2, frames: 1024)))
        XCTAssertNotNil(converter.convert(makeBuffer(sampleRate: 44_100, channels: 1, frames: 1024)))
    }

    func testEmptyBufferReturnsNil() {
        let converter = AppleAnalyzerAudioConverter(targetFormat: targetFormat)
        XCTAssertNil(converter.convert(makeBuffer(sampleRate: 48_000, channels: 2, frames: 0)))
    }
}
