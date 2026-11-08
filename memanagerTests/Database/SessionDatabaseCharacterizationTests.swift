import XCTest
import SQLite3
@testable import memanager

/// Characterization tests freezing the observable behavior of `SessionDatabase`
/// before any decomposition: schema creation on a fresh file, migration
/// idempotence on reopen, and round trips for the practice and snapshot
/// domains. Every test runs against a temporary database path; the production
/// `shared` instance is never touched.
final class SessionDatabaseCharacterizationTests: XCTestCase {
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDatabaseCharacterizationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("sessions.sqlite").path
    }

    override func tearDown() {
        let directory = (databasePath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: directory)
        databasePath = nil
        super.tearDown()
    }

    // MARK: - Schema

    func testFreshDatabaseCreatesExpectedTablesAtCurrentSchemaVersion() {
        _ = SessionDatabase(databasePath: databasePath)

        let inspector = SQLiteInspector(path: databasePath)
        defer { inspector.close() }

        XCTAssertEqual(inspector.userVersion(), 17, "schema version must stay frozen at 17 until an intentional migration is added")

        let expectedTables = [
            "sessions",
            "api_calls",
            "practice_cards",
            "practice_schedules",
            "practice_reviews",
            "session_snapshots",
            "debug_events",
            "job_workspaces",
            "workspace_documents",
            "workspace_journal",
            "kg_nodes",
            "kg_edges",
            "interviews",
            "interview_words",
            "interview_questions",
            "reference_answers",
            "answer_scores",
            "role_profiles"
        ]
        let tables = inspector.tableNames()
        for table in expectedTables {
            XCTAssertTrue(tables.contains(table), "expected table \(table) missing from fresh schema; found: \(tables.sorted())")
        }
    }

    func testReopeningExistingDatabaseIsIdempotent() {
        let first = SessionDatabase(databasePath: databasePath)
        let card = Self.makeCard(id: "card-reopen")
        first.upsertPracticeCard(card, schedule: Self.makeSchedule(cardID: card.id))

        // Second init on the same file simulates an app relaunch: createTables
        // and the full migration ladder rerun against the existing schema.
        let reopened = SessionDatabase(databasePath: databasePath)

        let inspector = SQLiteInspector(path: databasePath)
        defer { inspector.close() }
        XCTAssertEqual(inspector.userVersion(), 17, "rerunning migrations on an up-to-date database must not change user_version")

        let state = reopened.loadPracticeState()
        XCTAssertEqual(state.cards, [card], "data written before reopen must survive the migration rerun")
    }

    // MARK: - Practice round trip

    func testPracticeCardScheduleReviewRoundTrip() {
        let database = SessionDatabase(databasePath: databasePath)

        let card = Self.makeCard(id: "card-1")
        let schedule = Self.makeSchedule(cardID: card.id)
        database.upsertPracticeCard(card, schedule: schedule)

        let review = PracticeReview(
            id: "review-1",
            cardID: card.id,
            reviewedAt: Self.millisecondExactDate(offset: 120),
            grade: .correctHesitation,
            durationMs: 4500,
            selfReportedConfidence: 4,
            feedback: "solid recall",
            attemptTranscript: "spoke through the invariant"
        )
        let advanced = PracticeSchedule(
            cardID: card.id,
            repetitionCount: 1,
            easiness: 2.6,
            intervalDays: 1,
            nextReviewAt: Self.millisecondExactDate(offset: 86_400),
            lapses: 0,
            lastReviewedAt: Self.millisecondExactDate(offset: 120)
        )
        database.insertPracticeReview(review, schedule: advanced)

        let state = database.loadPracticeState()
        XCTAssertEqual(state.cards, [card])
        XCTAssertEqual(state.schedules, [advanced], "insertPracticeReview must replace the card's schedule with the advanced one")
        XCTAssertEqual(state.reviews, [review])
    }

    func testArchiveAndClearPracticeData() {
        let database = SessionDatabase(databasePath: databasePath)
        let card = Self.makeCard(id: "card-archive")
        database.upsertPracticeCard(card, schedule: Self.makeSchedule(cardID: card.id))

        database.archivePracticeCard(cardID: card.id)
        XCTAssertEqual(database.loadPracticeState().cards.first?.isArchived, true)

        database.clearPracticeData()
        let cleared = database.loadPracticeState()
        XCTAssertTrue(cleared.cards.isEmpty)
        XCTAssertTrue(cleared.schedules.isEmpty)
        XCTAssertTrue(cleared.reviews.isEmpty)
    }

    // MARK: - Snapshot round trip

    func testSessionSnapshotRoundTrip() {
        let database = SessionDatabase(databasePath: databasePath)
        let payload = Data([0x01, 0x02, 0x03, 0xFF])
        let snapshot = SessionSnapshotRecord(
            id: "snap-1",
            sessionId: "session-9",
            capturedAt: Self.millisecondExactDate(offset: 30),
            width: 1920,
            height: 1080,
            sizeBytes: payload.count,
            source: "hotkey",
            contentHash: "abc123",
            encryptedPayload: payload
        )

        // saveSessionSnapshot enqueues asynchronously on the same serial queue
        // that loadSessionSnapshots drains synchronously, so the read below is
        // ordered after the write.
        database.saveSessionSnapshot(snapshot)
        let loaded = database.loadSessionSnapshots(sessionId: "session-9")

        XCTAssertEqual(loaded, [snapshot])
        XCTAssertTrue(database.loadSessionSnapshots(sessionId: "other-session").isEmpty)
    }

    // MARK: - Fixtures

    /// Dates stored as whole milliseconds round trip exactly; sub-millisecond
    /// precision does not. Fixtures therefore use millisecond-exact instants.
    private static func millisecondExactDate(offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_720_000_000.125 + offset)
    }

    private static func makeCard(id: String) -> PracticeCard {
        PracticeCard(
            id: id,
            createdAt: millisecondExactDate(offset: 0),
            sessionID: "session-1",
            topicTag: "graphs",
            prompt: "Explain BFS layer expansion",
            idealReasoning: "Queue-driven frontier, visited set, O(V+E)",
            transcriptSnippet: "um, I think we just recurse",
            candidateAttemptSummary: "confused BFS with DFS",
            difficulty: .medium,
            sourceEvidence: .drill(drillID: "drill-7")
        )
    }

    private static func makeSchedule(cardID: String) -> PracticeSchedule {
        PracticeSchedule(
            cardID: cardID,
            repetitionCount: 0,
            easiness: 2.5,
            intervalDays: 0,
            nextReviewAt: millisecondExactDate(offset: 3600),
            lapses: 0,
            lastReviewedAt: nil
        )
    }
}

/// Read-only second connection used to assert on-disk schema facts without
/// widening `SessionDatabase`'s API for tests.
private final class SQLiteInspector {
    private var db: OpaquePointer?

    init(path: String) {
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func userVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW
        else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func tableNames() -> Set<String> {
        var names: Set<String> = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: cName))
            }
        }
        return names
    }
}
