import AppKit
import XCTest
@testable import memanager

@MainActor
final class ScreenshotPublicationTests: XCTestCase {
    func testQueuedCaptureDoesNotEnterReplacementSession() async {
        var sessionID = UUID()
        var recordedSessions: [UUID] = []
        let service = ScreenshotService(
            sessionIdentityProvider: { sessionID },
            manualCaptureRecorder: { _, id in recordedSessions.append(id) }
        )
        let identity = service.captureState.identity(sessionID: sessionID)
        service.publishManualScreenshot(fixture(), identity: identity)
        service.publishCaptureError(.captureFailure, identity: identity)
        sessionID = UUID()
        service.lastError = .noScreen
        await drainMainQueue()

        XCTAssertTrue(service.screenshots.isEmpty)
        XCTAssertTrue(recordedSessions.isEmpty)
        XCTAssertEqual(service.lastError?.localizedDescription, ScreenshotService.ScreenshotError.noScreen.localizedDescription)
    }

    func testClearRejectsQueuedPublicationAndPendingCacheFill() async throws {
        let sessionID = UUID()
        var recordedSessions: [UUID] = []
        let service = ScreenshotService(
            sessionIdentityProvider: { sessionID },
            manualCaptureRecorder: { _, id in recordedSessions.append(id) }
        )
        let identity = service.captureState.identity(sessionID: sessionID)
        let display = ScreenshotCaptureState.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let prewarm = try XCTUnwrap(service.captureState.beginCapture(for: identity, display: display, prewarm: true))
        service.screenshots = [fixture()]
        service.isCapturing = true
        service.publishManualScreenshot(fixture(), identity: identity)
        service.clearAll()
        XCTAssertFalse(service.captureState.finishCapture(prewarm, base64: "stale"))
        await drainMainQueue()

        XCTAssertTrue(service.screenshots.isEmpty)
        XCTAssertTrue(recordedSessions.isEmpty)
        XCTAssertFalse(service.isCapturing)
    }

    func testNewCaptureAfterClearPublishesAndRecordsOriginalIdentity() async {
        let sessionID = UUID()
        var recorded: [(UUID, UUID)] = []
        let service = ScreenshotService(
            sessionIdentityProvider: { sessionID },
            manualCaptureRecorder: { screenshot, id in recorded.append((screenshot.id, id)) }
        )
        let oldIdentity = service.captureState.identity(sessionID: sessionID)
        service.publishManualScreenshot(fixture(), identity: oldIdentity)
        service.clearAll()
        service.lastError = .captureFailure
        let current = fixture()
        let identity = service.captureState.identity(sessionID: sessionID)
        service.publishManualScreenshot(current, identity: identity)
        await drainMainQueue()

        XCTAssertEqual(service.screenshots.map(\.id), [current.id])
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, current.id)
        XCTAssertEqual(recorded.first?.1, sessionID)
        XCTAssertNil(service.lastError)
    }

    private func fixture() -> Screenshot {
        Screenshot(image: NSImage(size: NSSize(width: 2, height: 2)), capturedAt: Date())
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
