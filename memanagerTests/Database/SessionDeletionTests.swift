import XCTest
@testable import memanager

final class SessionDeletionTests: XCTestCase {
    private var database: SessionDatabase!

    override func setUpWithError() throws {
        database = SessionDatabase(databasePath: ":memory:")
        try sql("PRAGMA foreign_keys = ON")
        for id in ["removed", "kept"] {
            database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
        }
        database.flush()
        try sql("INSERT INTO quick_assist_threads (id, created_at, updated_at, origin_session_id) VALUES ('shared', 1, 1, 'removed'), ('empty', 1, 1, 'removed')")
        try sql("INSERT INTO quick_assist_calls (session_id, thread_id, turn_id, provider, model, started_at, status, created_at) VALUES ('removed', 'shared', 'old', 'OpenAI', 'fixture', 1, 'success', 1), ('kept', 'shared', 'new', 'OpenAI', 'fixture', 2, 'success', 2)")
        try sql("INSERT INTO transcript_entries (session_id, speaker, text, timestamp, created_at) VALUES ('removed', 'me', 'delete this', 1, 1), ('kept', 'me', 'keep this', 2, 2)")
        try sql("INSERT INTO memory_nodes (id, session_id, source_type, content, created_at, updated_at) VALUES ('old-memory', 'removed', 'quick_assist', 'old', 1, 1), ('kept-memory', 'kept', 'quick_assist', 'kept', 1, 1)")
        try sql("INSERT INTO memory_relationships (from_node_id, to_node_id, relation_type, created_at) VALUES ('old-memory', 'kept-memory', 'related', 1)")
        try sql("INSERT INTO quick_assist_thread_pins (thread_id, memory_node_id, created_at) VALUES ('shared', 'old-memory', 1), ('shared', 'kept-memory', 1)")
        try sql("INSERT INTO session_summaries (session_id, status, background_summary, created_at, updated_at) VALUES ('removed', 'completed', 'old summary', 1, 1)")
        try sql("INSERT INTO session_summary_action_items (id, session_id, title, ordinal, created_at) VALUES ('action', 'removed', 'old action', 0, 1)")
        try sql("INSERT INTO session_snapshots (id, session_id, captured_at, width, height, size_bytes, source, content_hash, encrypted_payload, created_at) VALUES ('snapshot', 'removed', 1, 1, 1, 1, 'test', 'hash', X'00', 1)")
    }

    override func tearDown() { database = nil }

    func testBatchDeletesAllSelectedSessionsAndSharedEvidence() throws {
        try database.deleteSessions(ids: ["removed", "kept"])
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("quick_assist_threads"), 0)
        XCTAssertEqual(try count("transcript_entries"), 0)
        XCTAssertEqual(try count("quick_assist_calls"), 0)
        XCTAssertEqual(try count("memory_nodes"), 0)
    }

    func testDeletesAFullPageOfEmptySessionsWithoutTouchingOtherHistory() throws {
        let ids = Set((0..<120).map { "empty-\($0)" })
        for id in ids {
            database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
        }
        try database.deleteSessions(ids: ids)
        XCTAssertEqual(Set(database.getRecentSessions(limit: 200).map(\.id)), ["kept", "removed"])
        XCTAssertEqual(try count("quick_assist_calls"), 2)
    }

    func testBatchRollsBackEarlierDeletesWhenLastSessionFails() throws {
        try sql("CREATE TRIGGER refuse_last BEFORE DELETE ON sessions WHEN OLD.id = 'removed' BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        XCTAssertThrowsError(try database.deleteSessions(ids: ["kept", "removed"]))
        XCTAssertEqual(try count("sessions"), 2)
        XCTAssertEqual(try count("transcript_entries"), 2)
        XCTAssertEqual(try count("quick_assist_calls"), 2)
    }

    func testDeletionRemovesEvidenceAndKeepsOtherSessionAndSharedConversation() throws {
        try database.deleteSession(id: "removed")
        XCTAssertNil(database.getSessionRecord(id: "removed"))
        XCTAssertNotNil(database.getSessionRecord(id: "kept"))
        XCTAssertEqual(try count("transcript_entries"), 1)
        XCTAssertEqual(try count("quick_assist_calls"), 1)
        XCTAssertEqual(try count("quick_assist_threads"), 1)
        XCTAssertEqual(try count("quick_assist_threads WHERE origin_session_id IS NOT NULL"), 0)
        XCTAssertEqual(try count("memory_nodes"), 1)
        XCTAssertEqual(try count("memory_relationships"), 0)
        XCTAssertEqual(try count("quick_assist_thread_pins"), 1)
        XCTAssertEqual(try count("session_snapshots"), 0)
        XCTAssertEqual(try count("session_summaries"), 0)
        XCTAssertEqual(try count("session_summary_action_items"), 0)
        XCTAssertEqual(database.getQuickAssistCallsForSession(sessionId: "kept").first?.turnId, "new")
        XCTAssertEqual(try database.performSyncThrowing { db in
            let check = try SQLiteStatement(db: db, sql: "PRAGMA foreign_key_check")
            return try check.stepRow()
        }, false)
    }

    func testFailureRollsBackEvidenceAndSessionTogether() throws {
        try sql("CREATE TRIGGER refuse_session_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture refuses deletion'); END")
        XCTAssertThrowsError(try database.deleteSession(id: "removed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("fixture refuses deletion"))
        }
        XCTAssertNotNil(database.getSessionRecord(id: "removed"))
        XCTAssertEqual(try count("quick_assist_calls"), 2)
        XCTAssertEqual(try count("memory_relationships"), 1)
        XCTAssertEqual(try count("session_snapshots"), 1)
        XCTAssertEqual(try count("session_summary_action_items"), 1)
    }

    func testMissingOrSQLShapedIDDoesNotDeleteOtherSessions() throws {
        try database.deleteSession(id: "' OR 1=1 --")
        XCTAssertEqual(try count("sessions"), 2)
        XCTAssertEqual(try count("quick_assist_calls"), 2)
        try database.deleteSession(id: "removed")
        try database.deleteSession(id: "removed")
        XCTAssertEqual(try count("sessions"), 1)
    }

    func testLateSummaryCannotRecreateDeletedEvidence() throws {
        try database.deleteSession(id: "removed")
        let summary = SessionSummaryRecord(sessionID: "removed", status: "completed", backgroundSummary: "late result", createdAt: Date(), updatedAt: Date())
        database.saveSessionSummary(summary, actionItems: [])
        XCTAssertNil(database.loadSessionSummary(sessionID: "removed"))
        let retained = SessionSummaryRecord(sessionID: "kept", status: "completed", backgroundSummary: "retained result", createdAt: Date(), updatedAt: Date())
        database.saveSessionSummary(retained, actionItems: [])
        XCTAssertEqual(database.loadSessionSummary(sessionID: "kept")?.0.backgroundSummary, "retained result")
    }

    func testSavedPracticeSurvivesAndDeletedMemoryLeavesSearchIndex() throws {
        try sql("INSERT INTO practice_cards (id, created_at, session_id, topic_tag, prompt, ideal_reasoning, transcript_snippet, candidate_attempt_summary, difficulty, evidence_kind) VALUES ('practice', 1, 'removed', 'topic', 'question', 'reasoning', 'saved excerpt', 'attempt', 'easy', 'transcript')")
        let hasFTS = database.performSync { _ in database.memoryFTSSupported }
        if hasFTS {
            try sql("INSERT INTO memory_nodes_fts (node_id, content) VALUES ('old-memory', 'unicorn')")
        }
        try database.deleteSession(id: "removed")
        XCTAssertEqual(try count("practice_cards"), 1)
        if hasFTS {
            XCTAssertEqual(try count("memory_nodes_fts WHERE memory_nodes_fts MATCH 'unicorn'"), 0)
        }
    }

    private func sql(_ text: String) throws {
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: text).executeStep()
        }
    }

    private func count(_ table: String) throws -> Int {
        try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM \(table)")
            _ = try statement.stepRow()
            return statement.columnInt(0)
        }
    }
}
