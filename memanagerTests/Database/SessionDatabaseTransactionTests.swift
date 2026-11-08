import XCTest
import SQLite3
@testable import memanager

final class SessionDatabaseTransactionTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "transaction-tests-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        try? database.performSyncThrowing { db in
            let statement = try SQLiteStatement(
                db: db,
                sql: "CREATE TABLE IF NOT EXISTS tx_probe (id TEXT PRIMARY KEY, value TEXT)"
            )
            try statement.executeStep()
        }
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

    func testBeginFailureThrowsWithoutRunningBody() throws {
        try database.performSyncThrowing { db in
            _ = sqlite3_exec(db, "PRAGMA busy_timeout = 50", nil, nil, nil)
        }

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) }

        var bodyRan = false
        XCTAssertThrowsError(
            try database.performSyncThrowing { db in
                try database.withTransactionThrowing(db) {
                    bodyRan = true
                }
            }
        ) { error in
            guard case DatabaseError.beginFailed = error else {
                return XCTFail("Expected beginFailed, got \(error)")
            }
        }
        XCTAssertFalse(bodyRan, "The body must never run untransacted when BEGIN fails")
    }

    func testBodyThrowRollsBackAndRethrowsOriginalError() throws {
        struct BodyError: Error {}

        XCTAssertThrowsError(
            try database.performSyncThrowing { db in
                try database.withTransactionThrowing(db) {
                    let insert = try SQLiteStatement(
                        db: db,
                        sql: "INSERT INTO tx_probe (id, value) VALUES ('a', 'doomed')"
                    )
                    try insert.executeStep()
                    throw BodyError()
                }
            }
        ) { error in
            XCTAssertTrue(error is BodyError, "The original body error must surface, got \(error)")
        }

        let rowCount = try countProbeRows()
        XCTAssertEqual(rowCount, 0, "The insert must be rolled back")
    }

    func testCommitPersistsWrites() throws {
        try database.performSyncThrowing { db in
            try database.withTransactionThrowing(db) {
                let insert = try SQLiteStatement(
                    db: db,
                    sql: "INSERT INTO tx_probe (id, value) VALUES ('a', 'kept')"
                )
                try insert.executeStep()
            }
        }

        XCTAssertEqual(try countProbeRows(), 1)
    }

    func testClearHubMemorySurfacesDatabaseFailure() throws {
        try database.performSyncThrowing { db in
            let trigger = try SQLiteStatement(db: db, sql: "CREATE TRIGGER block_memory_clear BEFORE DELETE ON memory_retrieval_events BEGIN SELECT RAISE(ABORT, 'memory is locked'); END")
            try trigger.executeStep()
            let insert = try SQLiteStatement(db: db, sql: "INSERT INTO memory_retrieval_events (query_source, query_text, created_at) VALUES ('test', 'sample', 1)")
            try insert.executeStep()
        }
        XCTAssertThrowsError(try database.clearHubMemory()) { error in
            XCTAssertTrue(error.localizedDescription.contains("memory is locked"))
        }
        let count = try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM memory_retrieval_events")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
        XCTAssertEqual(count, 1)
    }

    func testStatementPrepareFailureThrowsWithSQL() throws {
        XCTAssertThrowsError(
            try database.performSyncThrowing { db in
                _ = try SQLiteStatement(db: db, sql: "SELECT * FROM table_that_does_not_exist")
            }
        ) { error in
            guard case DatabaseError.prepareFailed(let sql, _) = error else {
                return XCTFail("Expected prepareFailed, got \(error)")
            }
            XCTAssertTrue(sql.contains("table_that_does_not_exist"))
        }
    }

    func testStatementStepFailureThrowsOnConstraintViolation() throws {
        try database.performSyncThrowing { db in
            let first = try SQLiteStatement(db: db, sql: "INSERT INTO tx_probe (id, value) VALUES ('dup', '1')")
            try first.executeStep()
        }

        XCTAssertThrowsError(
            try database.performSyncThrowing { db in
                let second = try SQLiteStatement(db: db, sql: "INSERT INTO tx_probe (id, value) VALUES ('dup', '2')")
                try second.executeStep()
            }
        ) { error in
            guard case DatabaseError.stepFailed = error else {
                return XCTFail("Expected stepFailed, got \(error)")
            }
        }
    }

    private func countProbeRows() throws -> Int {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM tx_probe")
            guard try query.stepRow() else { return 0 }
            return query.columnInt(0)
        }
    }
}
