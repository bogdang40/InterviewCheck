import AppKit
import XCTest
@testable import memanager

@MainActor
final class SessionDraftPersistenceTests: SessionControllerDatabaseTestCase {
    func testRepeatedResetDoesNotCreateSessionsOrPlaceholderThreads() throws {
        for _ in 0..<50 { controller.resetSessionStateForTesting() }
        XCTAssertTrue(database.getRecentSessions().isEmpty)
        XCTAssertTrue(logger.getQuickAssistThreads(limit: 100).isEmpty)
        XCTAssertNil(controller.session.startedAt)
        XCTAssertNil(controller.session.activeModeSnapshotID)
    }

    func testFailedCaptureStartLeavesNoHistory() {
        controller.resetSessionStateForTesting()
        controller.syncSessionStateForTesting(with: .starting)
        controller.syncSessionStateForTesting(with: .idle)
        XCTAssertTrue(database.getRecentSessions().isEmpty)
    }

    func testUnavailableProviderRejectsQuestionWithoutSavingSessionOrThread() {
        controller.resetSessionStateForTesting()
        controller.aiProvider = nil
        controller.quickAssist(questionOverride: "Explain this algorithm")
        XCTAssertEqual(controller.errorMessage, AIProviderError.invalidAPIKey.localizedDescription)
        XCTAssertFalse(controller.isQuickAssistLoading)
        XCTAssertTrue(database.getRecentSessions().isEmpty)
        XCTAssertTrue(logger.getQuickAssistThreads(limit: 100).isEmpty)
        XCTAssertNil(controller.session.startedAt)
    }

    func testResetKeepsFreshThreadIntentWhenHistoryIsRefreshed() {
        logger.createQuickAssistThread(threadId: "old-thread", title: "Older conversation", originSessionId: nil)
        controller.resetSessionStateForTesting()
        controller.refreshQuickAssistThreads()
        controller.ensureActiveQuickAssistThreadLoaded(selectNewest: false)
        XCTAssertNil(controller.activeQuickAssistThreadID)
        XCTAssertEqual(logger.getQuickAssistThreads(limit: 100).map(\.id), ["old-thread"])
        let freshID = controller.ensureActiveQuickAssistThread()
        XCTAssertEqual(freshID, controller.session.id.uuidString)
        XCTAssertEqual(Set(logger.getQuickAssistThreads(limit: 100).map(\.id)), ["old-thread", freshID])
    }

    func testExplicitHistorySelectionAfterResetKeepsTheChosenThread() {
        logger.createQuickAssistThread(threadId: "chosen", title: "Chosen conversation", originSessionId: nil)
        controller.resetSessionStateForTesting()
        controller.openQuickAssistThread(threadID: "chosen", showQuickAssistView: false)
        XCTAssertEqual(controller.ensureActiveQuickAssistThread(), "chosen")
        XCTAssertEqual(logger.getQuickAssistThreads(limit: 100).map(\.id), ["chosen"])
    }

    func testRecordingBeginsHistoryOnceAndResetDoesNotAddAnEmptyReplacement() {
        controller.resetSessionStateForTesting()
        let id = controller.session.id.uuidString
        controller.syncSessionStateForTesting(with: .recording)
        controller.syncSessionStateForTesting(with: .recording)
        XCTAssertEqual(database.getRecentSessions().map(\.id), [id])
        XCTAssertEqual(database.getSessionRecord(id: id)?.state, "listening")
        controller.resetSessionStateForTesting()
        XCTAssertEqual(database.getRecentSessions().map(\.id), [id])
        XCTAssertNotNil(database.getSessionRecord(id: id)?.endedAt)
    }

    func testManualCaptureCreatesHistoryWithoutRecordingAndClearingDoesNotCreateAnother() {
        controller.resetSessionStateForTesting()
        controller.persistManualScreenshots([Screenshot(image: NSImage(size: NSSize(width: 2, height: 2)), capturedAt: Date())], capturedSessionID: controller.session.id)
        let id = controller.session.id.uuidString
        XCTAssertEqual(database.getSessionRecord(id: id)?.screenshotCount, 1)
        controller.resetSessionStateForTesting()
        controller.persistManualScreenshots([], capturedSessionID: controller.session.id)
        XCTAssertEqual(database.getRecentSessions().map(\.id), [id])
    }

    func testQueuedScreenshotPublisherCannotCreateHistoryAfterReset() async {
        controller.resetSessionStateForTesting()
        let oldID = controller.session.id
        let screenshot = Screenshot(image: NSImage(size: NSSize(width: 2, height: 2)), capturedAt: Date())
        // Queue the old array on Combine's receive(on: .main), then replace
        // the session before that subscription is delivered.
        controller.screenshotService.screenshots = [screenshot]
        controller.resetSessionStateForTesting()
        controller.persistManualScreenshots([screenshot], capturedSessionID: oldID)
        let drained = expectation(description: "queued screenshot subscriptions drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(database.getRecentSessions().isEmpty)
        XCTAssertNil(controller.session.startedAt)
        XCTAssertTrue(controller.session.screenshots.isEmpty)
    }

    func testRequestStartCreatesOneSessionAndExistingHistoryKeepsItsDates() {
        controller.resetSessionStateForTesting()
        controller.beginSessionHistoryIfNeeded()
        let id = controller.session.id
        let start = database.getSessionRecord(id: id.uuidString)?.startedAt
        logger.logSessionEnded(sessionId: id)
        let end = database.getSessionRecord(id: id.uuidString)?.endedAt
        controller.beginSessionHistoryIfNeeded()
        controller.beginSessionHistoryIfNeeded()
        XCTAssertEqual(database.getRecentSessions().map(\.id), [id.uuidString])
        XCTAssertEqual(database.getSessionRecord(id: id.uuidString)?.startedAt, start)
        XCTAssertEqual(database.getSessionRecord(id: id.uuidString)?.endedAt, end)
    }
}
