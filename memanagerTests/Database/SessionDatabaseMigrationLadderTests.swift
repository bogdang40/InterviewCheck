import XCTest
import SQLite3
@testable import memanager

/// Tests for the data driven migration ladder: a failed step must stop the
/// ladder (so later steps can never stamp over it), retry on the next run,
/// and gate its backfills on DDL success. Plus the v15 upgrade path.
final class SessionDatabaseMigrationLadderTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "ladder-tests-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database = nil
        if let databasePath {
            try? FileManager.default.removeItem(atPath: databasePath)
            try? FileManager.default.removeItem(atPath: databasePath + "-wal")
            try? FileManager.default.removeItem(atPath: databasePath + "-shm")
        }
        super.tearDown()
    }

    // MARK: - Ladder mechanics (synthetic steps above the real head)

    func testFailedStepStopsLadderAndLaterStepsCannotStampOverIt() throws {
        let poisoned = MigrationStep(
            version: 100,
            statements: ["CREATE BROKEN SYNTAX ("]
        )
        let follower = MigrationStep(
            version: 101,
            statements: ["CREATE TABLE IF NOT EXISTS ladder_follower (id TEXT PRIMARY KEY)"]
        )

        database.runMigrations(steps: [poisoned, follower])

        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion,
                       "A failed step must withhold its stamp and stop the ladder")
        XCTAssertFalse(try tableExists("ladder_follower"),
                       "Steps after the failure must not run at all")
    }

    func testFailedStepRetriesOnNextRunOnceFixed() throws {
        let poisoned = MigrationStep(version: 100, statements: ["CREATE BROKEN SYNTAX ("])
        database.runMigrations(steps: [poisoned])
        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion)

        let fixed = MigrationStep(
            version: 100,
            statements: ["CREATE TABLE IF NOT EXISTS ladder_fixed (id TEXT PRIMARY KEY)"]
        )
        let follower = MigrationStep(
            version: 101,
            statements: ["CREATE TABLE IF NOT EXISTS ladder_follower (id TEXT PRIMARY KEY)"]
        )
        database.runMigrations(steps: [fixed, follower])

        XCTAssertEqual(try readUserVersion(), 101)
        XCTAssertTrue(try tableExists("ladder_fixed"))
        XCTAssertTrue(try tableExists("ladder_follower"))
    }

    func testBackfillFailureWithholdsTheStamp() throws {
        let step = MigrationStep(
            version: 100,
            statements: ["CREATE TABLE IF NOT EXISTS ladder_backfill (id TEXT PRIMARY KEY)"],
            backfills: ["UPDATE table_that_does_not_exist SET x = 1"]
        )

        database.runMigrations(steps: [step])

        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion,
                       "A failed backfill must withhold the stamp so the step retries")
    }

    func testBackfillsDoNotRunWhenDDLFailed() throws {
        try database.performSyncThrowing { db in
            let probe = try SQLiteStatement(
                db: db,
                sql: "CREATE TABLE IF NOT EXISTS backfill_probe (id TEXT PRIMARY KEY, touched INTEGER DEFAULT 0)"
            )
            try probe.executeStep()
            let seed = try SQLiteStatement(db: db, sql: "INSERT INTO backfill_probe (id) VALUES ('row')")
            try seed.executeStep()
        }

        let step = MigrationStep(
            version: 100,
            statements: ["CREATE BROKEN SYNTAX ("],
            backfills: ["UPDATE backfill_probe SET touched = 1"]
        )
        database.runMigrations(steps: [step])

        let touched = try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT touched FROM backfill_probe WHERE id = 'row'")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
        XCTAssertEqual(touched, 0, "Backfills must never run against half applied DDL")
    }

    // MARK: - v15 upgrade path

    func testUpgradeFromV14RecreatesTheV15Indices() throws {
        try database.performSyncThrowing { db in
            _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_quick_assist_calls_started_at", nil, nil, nil)
            _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_transcript_entries_session_ts", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA user_version = 14", nil, nil, nil)
        }
        database = nil

        // Reopening runs the ladder from v15 up to the current head.
        database = SessionDatabase(databasePath: databasePath)

        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion)
        XCTAssertTrue(try indexExists("idx_quick_assist_calls_started_at"))
        XCTAssertTrue(try indexExists("idx_transcript_entries_session_ts"))
    }

    // MARK: - v16 upgrade path

    func testUpgradeFromV15CreatesWorkspaceAndKnowledgeTables() throws {
        try database.performSyncThrowing { db in
            for table in ["job_workspaces", "workspace_documents", "workspace_journal", "kg_nodes", "kg_edges"] {
                _ = sqlite3_exec(db, "DROP TABLE IF EXISTS \(table)", nil, nil, nil)
            }
            _ = sqlite3_exec(db, "PRAGMA user_version = 15", nil, nil, nil)
        }
        database = nil

        database = SessionDatabase(databasePath: databasePath)

        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion)
        for table in ["job_workspaces", "workspace_documents", "workspace_journal", "kg_nodes", "kg_edges"] {
            XCTAssertTrue(try tableExists(table), "v16 must recreate \(table)")
        }
        XCTAssertTrue(try indexExists("idx_kg_edges_from"))
        XCTAssertTrue(try indexExists("idx_workspace_journal_workspace"))
    }

    // MARK: - v17 upgrade path

    func testUpgradeFromV16CreatesInterviewTables() throws {
        let tables = ["interviews", "interview_words", "interview_questions", "reference_answers",
                      "answer_scores", "role_profiles"]
        try database.performSyncThrowing { db in
            for table in tables { _ = sqlite3_exec(db, "DROP TABLE IF EXISTS \(table)", nil, nil, nil) }
            _ = sqlite3_exec(db, "PRAGMA user_version = 16", nil, nil, nil)
        }
        database = nil

        database = SessionDatabase(databasePath: databasePath)

        XCTAssertEqual(try readUserVersion(), 17)
        for table in tables {
            XCTAssertTrue(try tableExists(table), "v17 must create \(table)")
        }
        XCTAssertTrue(try indexExists("idx_interview_words_interview"))
    }

    func testFreshDatabaseLandsAtCurrentVersionWithV15Indices() throws {
        XCTAssertEqual(try readUserVersion(), SessionDatabaseMigrationSteps.currentVersion)
        XCTAssertTrue(try indexExists("idx_quick_assist_calls_started_at"))
        XCTAssertTrue(try indexExists("idx_transcript_entries_session_ts"))
    }

    // MARK: - Helpers

    private func readUserVersion() throws -> Int {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "PRAGMA user_version")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(
                db: db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
            )
            query.bindText(name, at: 1)
            _ = try query.stepRow()
            return query.columnInt(0) > 0
        }
    }

    private func indexExists(_ name: String) throws -> Bool {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(
                db: db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?"
            )
            query.bindText(name, at: 1)
            _ = try query.stepRow()
            return query.columnInt(0) > 0
        }
    }
}
