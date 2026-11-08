import AVFoundation
import XCTest
@testable import InterviewCheck

final class MicLevelMeterTests: XCTestCase {
    private func buffer(amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = amplitude * sin(Float(index) * 0.1) }
        return buffer
    }

    func testSilenceIsZeroAndLoudIsHigh() {
        XCTAssertEqual(MicLevelMeter.rms(buffer(amplitude: 0)), 0)
        let speech = MicLevelMeter.rms(buffer(amplitude: 0.05))
        let loud = MicLevelMeter.rms(buffer(amplitude: 0.9))
        XCTAssertGreaterThan(speech, 0.3)
        XCTAssertGreaterThan(loud, speech)
        XCTAssertLessThanOrEqual(loud, 1)
    }

    func testDeviceListHasUniqueIDs() {
        let devices = AudioDeviceManager.inputDevices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
    }
}
