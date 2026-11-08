import XCTest
@testable import InterviewCheckKit

final class StreamClockTests: XCTestCase {
    /// 1 second of 48 kHz mono PCM16.
    private let second = 96_000

    func testContiguousChunksMapOffsetsExactly() {
        let clock = StreamClock()
        for index in 0..<10 {
            clock.recordSent(byteCount: second / 10, capturedAt: 100 + Double(index) * 0.1)
        }
        XCTAssertEqual(clock.hostTime(forOffset: 0)!, 100, accuracy: 1e-9)
        XCTAssertEqual(clock.hostTime(forOffset: 0.55)!, 100.55, accuracy: 1e-9)
        XCTAssertEqual(clock.breakCount, 0)
        XCTAssertEqual(clock.snapshot.count, 1)
    }

    func testSmallArrivalJitterStaysInOneRun() {
        let clock = StreamClock()
        clock.recordSent(byteCount: second / 10, capturedAt: 50.00)
        clock.recordSent(byteCount: second / 10, capturedAt: 50.13) // 30 ms late
        clock.recordSent(byteCount: second / 10, capturedAt: 50.18) // 20 ms early
        XCTAssertEqual(clock.breakCount, 0)
        XCTAssertEqual(clock.hostTime(forOffset: 0.25)!, 50.25, accuracy: 1e-9)
    }

    func testDroppedAudioStartsANewRunAndCountsABreak() {
        let clock = StreamClock()
        // Two seconds of audio, then three seconds lost, then one more second.
        clock.recordSent(byteCount: second * 2, capturedAt: 10)
        clock.recordSent(byteCount: second, capturedAt: 15)
        XCTAssertEqual(clock.breakCount, 1)
        // Deepgram saw 3 s of audio in total; offset 2.5 is in the second run.
        XCTAssertEqual(clock.hostTime(forOffset: 2.5)!, 15.5, accuracy: 1e-9)
        XCTAssertEqual(clock.hostTime(forOffset: 1.0)!, 11.0, accuracy: 1e-9)
    }

    func testQueuedChunksFlushedLateKeepTheirCaptureTimes() {
        let clock = StreamClock()
        // Captured while the socket was connecting, sent together later.
        for index in 0..<5 {
            clock.recordSent(byteCount: second / 5, capturedAt: 200 + Double(index) * 0.2)
        }
        XCTAssertEqual(clock.breakCount, 0)
        XCTAssertEqual(clock.hostTime(forOffset: 0.9)!, 200.9, accuracy: 1e-9)
    }

    func testResetForgetsTheOldConnection() {
        let clock = StreamClock()
        clock.recordSent(byteCount: second, capturedAt: 10)
        clock.reset()
        XCTAssertNil(clock.hostTime(forOffset: 0))
        clock.recordSent(byteCount: second, capturedAt: 40)
        XCTAssertEqual(clock.hostTime(forOffset: 0.5)!, 40.5, accuracy: 1e-9)
        XCTAssertEqual(clock.breakCount, 0)
    }

    func testCaptureStartSubtractsTheChunkDuration() {
        let clock = StreamClock()
        XCTAssertEqual(clock.captureStart(ofBytes: second / 4, arrivedAt: 12), 11.75, accuracy: 1e-9)
    }
}
