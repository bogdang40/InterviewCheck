import XCTest
@testable import memanager

final class ScreenshotCaptureStateTests: XCTestCase {
    private let display = ScreenshotCaptureState.Display(
        id: 1, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800)
    )
    private let time = Date(timeIntervalSince1970: 1_000)

    func testCacheRequiresMatchingSessionDisplayAndGeometry() throws {
        let state = ScreenshotCaptureState()
        let identity = state.identity(sessionID: UUID())
        let request = try XCTUnwrap(state.beginCapture(for: identity, display: display))
        state.finishCapture(request, base64: "first screen", capturedAt: time)

        XCTAssertEqual(state.cachedBase64(for: identity, display: display, now: time), "first screen")
        XCTAssertNil(state.cachedBase64(for: state.identity(sessionID: UUID()), display: display, now: time))
        let otherDisplay = ScreenshotCaptureState.Display(id: 2, bounds: display.bounds)
        XCTAssertNil(state.cachedBase64(for: identity, display: otherDisplay, now: time))
        let resizedDisplay = ScreenshotCaptureState.Display(
            id: display.id, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertNil(state.cachedBase64(for: identity, display: resizedDisplay, now: time))
    }

    func testCacheExpiresAndRejectsClockRollback() throws {
        let state = ScreenshotCaptureState(validity: 3.5)
        let identity = state.identity(sessionID: UUID())
        let request = try XCTUnwrap(state.beginCapture(for: identity, display: display))
        state.finishCapture(request, base64: "image", capturedAt: time)

        XCTAssertEqual(state.cachedBase64(for: identity, display: display, now: time.addingTimeInterval(3.49)), "image")
        XCTAssertNil(state.cachedBase64(for: identity, display: display, now: time.addingTimeInterval(3.5)))
        XCTAssertNil(state.cachedBase64(for: identity, display: display, now: time.addingTimeInterval(-1)))
    }

    func testClearRejectsPendingPrewarmAndAllowsImmediateReplacement() throws {
        let state = ScreenshotCaptureState()
        let sessionID = UUID()
        let identity = state.identity(sessionID: sessionID)
        let pending = try XCTUnwrap(state.beginCapture(for: identity, display: display, prewarm: true))
        state.invalidate()

        XCTAssertFalse(state.isCurrent(identity))
        XCTAssertNil(state.beginCapture(for: identity, display: display))
        let replacementIdentity = state.identity(sessionID: sessionID)
        let replacement = try XCTUnwrap(state.beginCapture(for: replacementIdentity, display: display, prewarm: true))
        XCTAssertFalse(state.finishCapture(pending, base64: "stale", capturedAt: time))
        XCTAssertNil(state.cachedBase64(for: replacementIdentity, display: display, now: time))
        XCTAssertNil(state.beginCapture(for: replacementIdentity, display: display, prewarm: true))
        XCTAssertTrue(state.finishCapture(replacement, base64: "current", capturedAt: time))
        XCTAssertEqual(state.cachedBase64(for: replacementIdentity, display: display, now: time), "current")
    }

    func testDirectCaptureCannotBeOverwrittenByOlderPrewarm() throws {
        let state = ScreenshotCaptureState()
        let identity = state.identity(sessionID: UUID())
        let prewarm = try XCTUnwrap(state.beginCapture(for: identity, display: display, prewarm: true))
        let direct = try XCTUnwrap(state.beginCapture(for: identity, display: display))
        XCTAssertTrue(state.finishCapture(direct, base64: "newer", capturedAt: time))
        XCTAssertFalse(state.finishCapture(prewarm, base64: "older", capturedAt: time))
        XCTAssertEqual(state.cachedBase64(for: identity, display: display, now: time), "newer")
    }

    func testSwitchingDisplaysDoesNotWaitForPreviousPrewarm() throws {
        let state = ScreenshotCaptureState()
        let identity = state.identity(sessionID: UUID())
        let old = try XCTUnwrap(state.beginCapture(for: identity, display: display, prewarm: true))
        let otherDisplay = ScreenshotCaptureState.Display(id: 2, bounds: display.bounds)
        let current = try XCTUnwrap(state.beginCapture(for: identity, display: otherDisplay, prewarm: true))
        XCTAssertFalse(state.finishCapture(old, base64: nil))
        XCTAssertNil(state.beginCapture(for: identity, display: otherDisplay, prewarm: true))
        XCTAssertTrue(state.finishCapture(current, base64: "second screen", capturedAt: time))
        XCTAssertEqual(state.cachedBase64(for: identity, display: otherDisplay, now: time), "second screen")
        XCTAssertNil(state.beginCapture(for: identity, display: otherDisplay, prewarm: true, now: time))
    }

    func testClearRemovesAlreadyCachedImage() throws {
        let state = ScreenshotCaptureState()
        let sessionID = UUID()
        let identity = state.identity(sessionID: sessionID)
        let request = try XCTUnwrap(state.beginCapture(for: identity, display: display))
        state.finishCapture(request, base64: "cached", capturedAt: time)
        state.invalidate()

        XCTAssertNil(state.cachedBase64(for: identity, display: display, now: time))
        XCTAssertNil(state.cachedBase64(for: state.identity(sessionID: sessionID), display: display, now: time))
    }
}
