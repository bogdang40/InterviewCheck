import XCTest
@testable import memanager

@MainActor
final class ThreadBatchDeletionTests: SessionControllerDatabaseTestCase {
    private func seedThreads() {
        for id in ["a", "b", "c"] {
            logger.createQuickAssistThread(threadId: id, title: id, originSessionId: nil)
        }
        controller.openQuickAssistThread(threadID: "a", showQuickAssistView: false)
    }

    func testDeletesOnlySelectedThreadsAndKeepsCurrentThread() throws {
        seedThreads()
        try controller.deleteQuickAssistThreads(ids: ["b", "c"])
        XCTAssertEqual(logger.getQuickAssistThreads(limit: 100).map(\.id), ["a"])
        XCTAssertEqual(controller.activeQuickAssistThreadID, "a")
    }

    func testDeletingLastThreadsStaysEmptyUntilUserStartsAThread() throws {
        seedThreads()
        try controller.deleteQuickAssistThreads(ids: ["a", "b", "c"])
        controller.refreshQuickAssistThreads()
        controller.ensureActiveQuickAssistThreadLoaded(selectNewest: false)
        XCTAssertTrue(logger.getQuickAssistThreads(limit: 100).isEmpty)
        XCTAssertTrue(controller.quickAssistTurns.isEmpty)
        XCTAssertNil(controller.quickAssistResponse)
        XCTAssertNil(controller.activeQuickAssistThreadID)
        let newID = controller.ensureActiveQuickAssistThread()
        XCTAssertEqual(logger.getQuickAssistThreads(limit: 100).map(\.id), [newID])
    }

    func testWholeSelectionRollsBackWhenLastDeleteFails() throws {
        seedThreads()
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: "CREATE TRIGGER reject_last BEFORE DELETE ON quick_assist_threads WHEN OLD.id = 'c' BEGIN SELECT RAISE(ABORT, 'last delete blocked'); END").executeStep()
        }
        XCTAssertThrowsError(try controller.deleteQuickAssistThreads(ids: ["a", "b", "c"]))
        XCTAssertEqual(Set(logger.getQuickAssistThreads(limit: 100).map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(controller.activeQuickAssistThreadID, "a")
    }

    func testGenerationCannotBeCancelledByBatchDeletion() throws {
        seedThreads()
        controller.isQuickAssistLoading = true
        controller.quickAssistStreamingDraft = "Still answering"
        XCTAssertThrowsError(try controller.deleteQuickAssistThreads(ids: ["a", "b"]))
        XCTAssertEqual(logger.getQuickAssistThreads(limit: 100).count, 3)
        XCTAssertTrue(controller.isQuickAssistLoading)
        XCTAssertEqual(controller.quickAssistStreamingDraft, "Still answering")
        controller.isQuickAssistLoading = false
    }

    func testThreadWithFailedRequestIsNotEmpty() throws {
        seedThreads()
        database.insertSession(SessionRecord(id: "s", startedAt: Date(), state: "ended"))
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: "INSERT INTO quick_assist_calls (session_id, thread_id, turn_id, provider, model, started_at, status, created_at) VALUES ('s', 'b', 'failed-turn', 'fixture', 'fixture', 1, 'error', 1)").executeStep()
        }
        let threads = logger.getQuickAssistThreads(limit: 100)
        XCTAssertEqual(threads.first { $0.id == "b" }?.turnCount, 0)
        XCTAssertEqual(threads.first { $0.id == "b" }?.hasRecordedCalls, true)
        XCTAssertEqual(threads.first { $0.id == "c" }?.hasRecordedCalls, false)
    }
}
