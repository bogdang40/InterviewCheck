import XCTest
@testable import memanager

final class ReviewSessionHistoryTests: XCTestCase {
    private var database: SessionDatabase!

    override func setUp() { database = SessionDatabase(databasePath: ":memory:") }
    override func tearDown() { database = nil }

    private func seed(_ id: String, date: TimeInterval = 1, transcript: String? = nil) {
        database.insertSession(SessionRecord(id: id, startedAt: Date(timeIntervalSince1970: date), state: "idle", transcript: transcript))
    }

    private func sql(_ text: String) throws {
        try database.performSyncThrowing { db in try SQLiteStatement(db: db, sql: text).executeStep() }
    }

    func testOldRecordedSessionIsVisibleBehindMoreThanOnePageOfEmptyRows() throws {
        seed("recorded", transcript: "Useful saved transcript")
        for index in 0..<250 { seed("empty-\(index)", date: 100 + Double(index)) }
        let page = try database.getReviewSessions()
        XCTAssertEqual(page.sessions.map(\.id), ["recorded"])
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.emptyCount, 250)
        XCTAssertTrue(page.emptySessionIDs.isEmpty)

        let first = try database.getReviewSessions(includeEmpty: true)
        XCTAssertEqual(first.sessions.count, 120)
        XCTAssertEqual(first.totalCount, 251)
        let more = try database.getReviewSessions(limit: 240, includeEmpty: true)
        XCTAssertEqual(more.sessions.count, 240)
        XCTAssertEqual(Array(more.sessions.prefix(120)).map(\.id), first.sessions.map(\.id))
        XCTAssertEqual(try database.getReviewSessions(limit: 360, includeEmpty: true).sessions.count, 251)
    }

    func testChildEvidenceProtectsLegacyEmptyMetadataAndRestoresCardCounts() throws {
        for id in ["transcript", "screenshot", "answer", "failed", "memory", "summary", "snapshot", "setup"] { seed(id) }
        try sql("INSERT INTO transcript_entries (session_id, speaker, text, timestamp, created_at) VALUES ('transcript', 'me', 'Two recorded words', 1, 1)")
        try sql("INSERT INTO screenshots (session_id, captured_at, source, created_at) VALUES ('screenshot', 1, 'manual', 1)")
        try sql("INSERT INTO api_calls (session_id, call_type, provider, model, started_at, status, created_at) VALUES ('answer', 'solve', 'fixture', 'fixture', 1, 'success', 1), ('failed', 'solve', 'fixture', 'fixture', 1, 'error', 1)")
        try sql("INSERT INTO memory_nodes (id, session_id, source_type, content, created_at, updated_at) VALUES ('m', 'memory', 'quick_assist', 'saved', 1, 1)")
        try sql("INSERT INTO session_summaries (session_id, status, background_summary, created_at, updated_at) VALUES ('summary', 'completed', 'saved summary', 1, 1)")
        try sql("INSERT INTO session_snapshots (id, session_id, captured_at, width, height, size_bytes, source, content_hash, encrypted_payload, created_at) VALUES ('replay', 'snapshot', 1, 1, 1, 1, 'test', 'hash', X'00', 1)")
        try sql("INSERT INTO session_mode_snapshots (snapshot_id, session_id, captured_at, title, prompt_text, attachments_json, created_at) VALUES ('mode', 'setup', 1, 'Automatic setup', '', '[]', 1)")
        let page = try database.getReviewSessions(includeEmpty: true)
        XCTAssertEqual(page.emptySessionIDs, ["setup"])
        XCTAssertEqual(page.sessions.first { $0.id == "transcript" }?.transcript, "Two recorded words")
        XCTAssertEqual(page.sessions.first { $0.id == "transcript" }?.transcriptWordCount, 3)
        XCTAssertEqual(page.sessions.first { $0.id == "screenshot" }?.screenshotCount, 1)
        XCTAssertEqual(page.sessions.first { $0.id == "answer" }?.hasResponse, true)
        XCTAssertEqual(try database.getReviewSessions().sessions.count, 7)
        XCTAssertNil(database.getSessionRecord(id: "transcript")?.transcript, "Display repair must not rewrite user data")
    }

    func testCountsDecreaseAfterDeletionInsteadOfPresentingThePageSizeAsTotal() throws {
        for index in 0..<125 { seed("e\(index)") }
        let first = try database.getReviewSessions(includeEmpty: true)
        try database.deleteSessions(ids: Set(first.sessions.map(\.id)))
        let remaining = try database.getReviewSessions(includeEmpty: true)
        XCTAssertEqual(remaining.totalCount, 5)
        XCTAssertEqual(remaining.emptyCount, 5)
        XCTAssertEqual(remaining.sessions.count, 5)
    }
}
