import XCTest
@testable import InterviewCheck

final class AudioStatusModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func model(recording: Bool = true, mic: DeepgramConnectionState = .connected,
                       call: DeepgramConnectionState = .connected, callActive: Bool = true,
                       micAge: TimeInterval? = 0.5, callAge: TimeInterval? = 0.5) -> AudioStatusModel {
        AudioStatusModel(isRecording: recording, micState: mic, callState: call, isCallAudioActive: callActive,
                         micLastBuffer: micAge.map { now.addingTimeInterval(-$0) },
                         callLastBuffer: callAge.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testBothConnected() {
        let status = model()
        XCTAssertEqual(status.mic.level, .ok)
        XCTAssertEqual(status.call.level, .ok)
        XCTAssertFalse(status.hasProblem)
    }

    func testStartingIsWaitingNotAProblem() {
        let status = model(recording: false)
        XCTAssertEqual(status.mic.level, .waiting)
        XCTAssertFalse(status.hasProblem)
    }

    func testCallAudioNotCapturedPointsAtThePermission() {
        let status = model(callActive: false)
        XCTAssertEqual(status.call.level, .problem)
        XCTAssertTrue(status.call.detail.contains("Screen & System Audio Recording"))
    }

    func testSilentCallIsFlaggedAfterFiveSeconds() {
        XCTAssertEqual(model(callAge: 4).call.level, .ok)
        let stale = model(callAge: 12)
        XCTAssertEqual(stale.call.level, .problem)
        XCTAssertTrue(stale.call.detail.contains("12 s"))
    }

    func testTranscriptionErrorsAreShown() {
        let status = model(mic: .error("invalid key"))
        XCTAssertEqual(status.mic.level, .problem)
        XCTAssertTrue(status.mic.detail.contains("invalid key"))
        XCTAssertEqual(model(call: .connecting).call.level, .waiting)
        XCTAssertEqual(model(call: .disconnected).call.level, .problem)
    }
}
