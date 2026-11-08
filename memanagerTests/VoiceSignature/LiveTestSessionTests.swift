import XCTest
@testable import memanager

@MainActor
final class LiveTestSessionTests: XCTestCase {
    func testCurrentRunFailureStopsSeededSessionAndShowsError() {
        let session = seededSession()
        session.receiveProcessingError(EagleError.invalidArgument, from: session.runID)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.currentLabel, .unknown)
        XCTAssertEqual(session.audioLevel, 0)
        XCTAssertEqual(session.errorMessage, "Voice recognition failed: \(EagleError.invalidArgument.localizedDescription)")
    }

    func testObsoleteRunFailureCannotStopCurrentSession() {
        let previous = seededSession()
        let oldRun = previous.runID
        previous.stop()
        let current = seededSession()
        current.receiveProcessingError(EagleError.invalidArgument, from: oldRun)
        XCTAssertTrue(current.isRunning)
        XCTAssertNil(current.errorMessage)
        XCTAssertEqual(current.currentLabel, .me)
        current.stop()
    }

    func testFailureDeliveredAfterStopIsIgnored() {
        let session = seededSession()
        let oldRun = session.runID
        session.stop()
        session.receiveProcessingError(EagleError.invalidArgument, from: oldRun)
        XCTAssertNil(session.errorMessage)
    }

    private func seededSession() -> LiveTestSession {
        LiveTestSession.seeded(label: .me, score: 0.9, scores: [0.9], audioLevel: 0.5)
    }
}
