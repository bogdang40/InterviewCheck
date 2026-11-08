import XCTest
@testable import memanager

@MainActor
final class SessionControllerHistoryDeletionTests: SessionControllerDatabaseTestCase {
    func testActiveSessionRejectsEntireBatchBeforeDeletingOtherSessions() throws {
        let active = Session()
        controller.session = active
        logger.logSessionStarted(session: active, provider: "fixture", model: "fixture")
        database.insertSession(SessionRecord(id: "older", startedAt: Date(), state: "ended"))
        XCTAssertThrowsError(try controller.deleteHistorySessions(ids: [active.id.uuidString, "older"]))
        XCTAssertNotNil(database.getSessionRecord(id: "older"))
        XCTAssertNotNil(database.getSessionRecord(id: active.id.uuidString))
    }

    func testRemovingLastSessionClearsItsActiveAnswerWithoutRecreatingAThread() throws {
        database.insertSession(SessionRecord(id: "old", startedAt: Date(), state: "ended"))
        logger.createQuickAssistThread(threadId: "old-thread", title: "Old answer", originSessionId: "old")
        try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "INSERT INTO quick_assist_calls (session_id, thread_id, turn_id, provider, model, started_at, status, response_text, created_at) VALUES ('old', 'old-thread', ?, 'OpenAI', 'fixture', 1, 'success', 'Saved answer', 1)")
            statement.bindText(UUID().uuidString, at: 1)
            try statement.executeStep()
        }
        controller.openQuickAssistThread(threadID: "old-thread", showQuickAssistView: false)
        XCTAssertEqual(controller.quickAssistResponse, "Saved answer")
        try controller.deleteHistorySessions(ids: ["old"])
        XCTAssertNil(controller.quickAssistResponse)
        XCTAssertTrue(controller.quickAssistTurns.isEmpty)
        XCTAssertTrue(logger.getQuickAssistThreads(limit: 100).isEmpty)
    }

    func testActiveSessionCannotBeDeletedEvenIfStoredDatesLookEnded() throws {
        let session = Session()
        controller.session = session
        logger.logSessionStarted(session: session, provider: "fixture", model: "fixture")
        database.updateSessionEnded(sessionId: session.id.uuidString, endedAt: Date())
        database.flush()
        XCTAssertThrowsError(try controller.deleteHistorySession(id: session.id.uuidString))
        XCTAssertNotNil(database.getSessionRecord(id: session.id.uuidString))
    }

    func testEndedCurrentSessionCanBeDeletedAndCannotBeResumedFromMemory() throws {
        let session = Session()
        controller.session = session
        logger.logSessionStarted(session: session, provider: "fixture", model: "fixture")
        logger.logSessionEnded(sessionId: session.id)
        _ = controller.audioService.restoreTranscriptForResume("Deleted transcript", entries: [])
        controller.selectedReviewSessionID = session.id.uuidString
        database.flush()
        try controller.deleteHistorySession(id: session.id.uuidString)
        XCTAssertNil(database.getSessionRecord(id: session.id.uuidString))
        XCTAssertNotEqual(controller.session.id, session.id)
        XCTAssertNil(controller.selectedReviewSessionID)
        XCTAssertNil(controller.currentSessionMetrics)
        XCTAssertEqual(controller.audioService.transcript, "")
    }

    func testDeletingUnrelatedSessionKeepsCurrentAnswerReadable() throws {
        let id = UUID().uuidString
        database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
        controller.quickAssistResponse = "Current answer"
        controller.quickAssistLastStableResponse = "Current answer"
        try controller.deleteHistorySession(id: id)
        XCTAssertEqual(controller.quickAssistResponse, "Current answer")
        XCTAssertEqual(controller.quickAssistLastStableResponse, "Current answer")
    }

    func testGenerationBlocksDeletionWithoutCancellingAnswer() throws {
        let id = UUID().uuidString
        database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
        database.flush()
        controller.isQuickAssistLoading = true
        controller.quickAssistStreamingDraft = "Answer in progress"
        XCTAssertThrowsError(try controller.deleteHistorySession(id: id))
        XCTAssertTrue(controller.isQuickAssistLoading)
        XCTAssertEqual(controller.quickAssistStreamingDraft, "Answer in progress")
        XCTAssertNotNil(database.getSessionRecord(id: id))
        controller.isQuickAssistLoading = false
    }

    func testFailedDeletionLeavesReviewSelectionIntact() throws {
        let id = UUID().uuidString
        database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
        controller.selectedReviewSessionID = id
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: "CREATE TRIGGER block_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'blocked'); END").executeStep()
        }
        XCTAssertThrowsError(try controller.deleteHistorySession(id: id))
        XCTAssertEqual(controller.selectedReviewSessionID, id)
        XCTAssertNotNil(database.getSessionRecord(id: id))
    }
}
