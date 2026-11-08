import XCTest
@testable import memanager

@MainActor
final class QuickAssistCancellationDeletionTests: SessionControllerDatabaseTestCase {
    func testLateCancellationAfterBatchDeletionDoesNotRecreateHistory() throws {
        let threadID = controller.ensureActiveQuickAssistThread()
        let tracker = QuickAssistCallTracker(record: QuickAssistCallRecord(
            sessionId: controller.session.id.uuidString, threadId: threadID,
            provider: "fixture", model: "fixture"
        ), database: database)
        controller.isQuickAssistLoading = true

        // The provider's cancellation callback can run after the UI loading
        // guard is released and the user has deleted the conversation.
        controller.cancelActiveTasks()
        XCTAssertFalse(controller.isQuickAssistLoading)
        try controller.deleteQuickAssistThreads(ids: [threadID])
        tracker.cancel()

        XCTAssertTrue(logger.getRecentQuickAssistCalls().isEmpty)
        XCTAssertTrue(logger.getQuickAssistThreads().isEmpty)
        XCTAssertNil(controller.activeQuickAssistThreadID)
    }
}
