import AVFoundation
import XCTest
@testable import InterviewCheck

final class SeparateStreamAudioRouterTests: XCTestCase {
    func testStereoRightOnlyInputDownmixesToMonoPCM16() throws {
        let router = makeRouter()
        let buffer = try makePlanarFloat32StereoBuffer(
            sampleRate: 48_000,
            frameCount: 512,
            left: 0.0,
            right: 1.0
        )

        let result = router.testConvertSystemBufferToPCM16(buffer)
        let (data, metrics) = try XCTUnwrap(result)
        let samples = decodePCM16Samples(data)

        XCTAssertEqual(samples.count, 512)
        XCTAssertEqual(metrics.sourceChannels, 2)
        XCTAssertEqual(metrics.frameLength, 512)
        XCTAssertTrue(metrics.conversionPath.contains("downmix_2_to_1"))

        let first = Double(samples[0]) / Double(Int16.max)
        XCTAssertEqual(first, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(metrics.rmsDb, -12.5)
        XCTAssertLessThan(metrics.rmsDb, -4.0)
    }

    func testInterleavedFloat32InputIsNormalizedAndConverted() throws {
        let router = makeRouter()
        let buffer = try makeInterleavedFloat32StereoBuffer(
            sampleRate: 48_000,
            frameCount: 480,
            left: 0.25,
            right: 0.25
        )

        let result = router.testConvertSystemBufferToPCM16(buffer)
        let (data, metrics) = try XCTUnwrap(result)

        XCTAssertEqual(data.count / MemoryLayout<Int16>.size, 480)
        XCTAssertEqual(metrics.sourceSampleRate, 48_000)
        XCTAssertEqual(metrics.sourceChannels, 2)
        XCTAssertTrue(metrics.conversionPath.contains("interleaved"))
        XCTAssertTrue(metrics.conversionPath.contains("normalize_float32"))
    }

    func testInterleavedInt16InputResamples44100To48000WithConsistentFrames() throws {
        let router = makeRouter()
        let sourceFrames = 4_410  // 100ms at 44.1k
        let buffer = try makeInterleavedInt16StereoBuffer(
            sampleRate: 44_100,
            frameCount: sourceFrames,
            left: 11_000,
            right: 7_000
        )

        let result = router.testConvertSystemBufferToPCM16(buffer)
        let (data, metrics) = try XCTUnwrap(result)

        let outputFrameCount = data.count / MemoryLayout<Int16>.size
        let expectedFrames = Int((Double(sourceFrames) * 48_000.0 / 44_100.0).rounded())

        XCTAssertLessThanOrEqual(abs(outputFrameCount - expectedFrames), 1)
        XCTAssertEqual(metrics.sourceSampleRate, 44_100)
        XCTAssertEqual(metrics.sourceChannels, 2)
        XCTAssertEqual(Int(metrics.frameLength), outputFrameCount)
        XCTAssertTrue(metrics.conversionPath.contains("resample_44100_to_48000"))
    }

    func testResampleConverterRemainsUsableAcrossSequentialBuffers() throws {
        let router = makeRouter()
        let firstBuffer = try makeInterleavedInt16StereoBuffer(
            sampleRate: 44_100,
            frameCount: 4_410,
            left: 11_000,
            right: 7_000
        )
        let secondBuffer = try makeInterleavedInt16StereoBuffer(
            sampleRate: 44_100,
            frameCount: 4_410,
            left: 9_000,
            right: 5_000
        )

        let firstResult = router.testConvertSystemBufferToPCM16(firstBuffer)
        let secondResult = router.testConvertSystemBufferToPCM16(secondBuffer)

        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        XCTAssertGreaterThan(secondResult?.0.count ?? 0, 0)
    }
}

private extension SeparateStreamAudioRouterTests {
    func makeRouter() -> SeparateStreamAudioRouter {
        SeparateStreamAudioRouter(dualStreamService: DualStreamDeepgramService())
    }

    func decodePCM16Samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }
    }

    func makePlanarFloat32StereoBuffer(
        sampleRate: Double,
        frameCount: Int,
        left: Float,
        right: Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<frameCount {
            channels[0][index] = left
            channels[1][index] = right
        }
        return buffer
    }

    func makeInterleavedFloat32StereoBuffer(
        sampleRate: Double,
        frameCount: Int,
        left: Float,
        right: Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let firstBuffer = audioBufferList[0]
        let samplePointer = try XCTUnwrap(firstBuffer.mData).assumingMemoryBound(to: Float.self)

        for frame in 0..<frameCount {
            let baseIndex = frame * 2
            samplePointer[baseIndex] = left
            samplePointer[baseIndex + 1] = right
        }
        audioBufferList[0].mDataByteSize = UInt32(frameCount * 2 * MemoryLayout<Float>.size)
        return buffer
    }

    func makeInterleavedInt16StereoBuffer(
        sampleRate: Double,
        frameCount: Int,
        left: Int16,
        right: Int16
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let firstBuffer = audioBufferList[0]
        let samplePointer = try XCTUnwrap(firstBuffer.mData).assumingMemoryBound(to: Int16.self)

        for frame in 0..<frameCount {
            let baseIndex = frame * 2
            samplePointer[baseIndex] = left
            samplePointer[baseIndex + 1] = right
        }
        audioBufferList[0].mDataByteSize = UInt32(frameCount * 2 * MemoryLayout<Int16>.size)
        return buffer
    }
}
