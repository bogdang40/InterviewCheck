import XCTest
import SQLite3
@testable import memanager

/// Regression tests for the session write path bugs: ended_at clobbering via
/// INSERT OR REPLACE, the primary key lookup that scanned 1000 sessions, lost
/// writes on quit, and non atomic thread deletion.
final class SessionWritePathIntegrityTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "write-path-tests-\(UUID().uuidString).sqlite"
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

    private func makeRecord(
        id: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        endedAt: Date? = nil,
        transcript: String = "hello"
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            state: "listening",
            transcript: transcript,
            transcriptWordCount: 1,
            screenshotCount: 0,
            hasResponse: false,
            provider: "OpenAI",
            model: "gpt-5.2"
        )
    }

    func testSessionUpdateAfterEndPreservesEndedAtAndCreatedAt() throws {
        let sessionId = "session-upsert"
        database.insertSession(makeRecord(id: sessionId))
        database.flush()

        let endedAt = Date(timeIntervalSince1970: 1_000_500)
        database.updateSessionEnded(sessionId: sessionId, endedAt: endedAt)
        database.flush()

        let createdAtBefore = try readCreatedAt(sessionId: sessionId)

        // The bug: any update after end reset ended_at to NULL and rewrote created_at.
        database.insertSession(makeRecord(id: sessionId, transcript: "hello updated"))
        database.flush()

        let record = try XCTUnwrap(database.getSessionRecord(id: sessionId))
        let recordedEnd = try XCTUnwrap(record.endedAt, "ended_at must survive later session updates")
        XCTAssertEqual(recordedEnd.timeIntervalSince1970, endedAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(record.transcript, "hello updated", "The update itself must still apply")
        XCTAssertEqual(try readCreatedAt(sessionId: sessionId), createdAtBefore, "created_at must not be rewritten")
    }

    func testGetSessionRecordFindsSessionsBeyondTheRecentWindow() {
        // The old implementation scanned getRecentSessions(limit: 1000) and
        // returned nil for anything older. Insert an old target plus newer
        // sessions and look the old one up directly by primary key.
        let oldest = makeRecord(id: "the-oldest", startedAt: Date(timeIntervalSince1970: 1))
        database.insertSession(oldest)
        for index in 0..<1000 {
            database.insertSession(
                makeRecord(id: "newer-\(index)", startedAt: Date(timeIntervalSince1970: Double(1000 + index)))
            )
        }
        database.flush()

        let found = database.getSessionRecord(id: "the-oldest")
        XCTAssertEqual(found?.id, "the-oldest")
        XCTAssertNil(database.getSessionRecord(id: "never-existed"))
    }

    func testFlushMakesQueuedAsyncWritesDurable() throws {
        let enteredQueue = expectation(description: "Writes are held before flush")
        let releaseWrites = DispatchSemaphore(value: 0)
        database.performAsync { _ in
            enteredQueue.fulfill()
            _ = releaseWrites.wait(timeout: .now() + 5)
        }
        defer {
            releaseWrites.signal()
            database.flush()
        }
        wait(for: [enteredQueue], timeout: 1)

        for index in 0..<25 {
            database.insertSession(makeRecord(id: "bulk-\(index)"))
        }

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
            releaseWrites.signal()
        }
        database.flush()

        // Query through an independent connection: a SessionDatabase getter
        // would itself drain the serial queue and conceal a broken flush.
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        do {
            let query = try SQLiteStatement(db: try XCTUnwrap(reader), sql: "SELECT COUNT(*) FROM sessions")
            XCTAssertTrue(try query.stepRow())
            XCTAssertEqual(query.columnInt(0), 25, "flush must commit queued writes before returning")
        }
    }

    func testFlushTimeoutDoesNotWaitForBlockedWrite() {
        let enteredQueue = expectation(description: "Database queue is blocked")
        let unblock = DispatchSemaphore(value: 0)
        database.performAsync { _ in
            enteredQueue.fulfill()
            _ = unblock.wait(timeout: .now() + 5)
        }
        defer {
            unblock.signal()
            database.flush()
        }
        wait(for: [enteredQueue], timeout: 1)

        let started = DispatchTime.now().uptimeNanoseconds
        database.flush(timeout: 0.01)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertLessThan(elapsed, 1, "flush must respect its timeout when pending work is blocked")
    }

    func testThreadDeletionIsAtomicUnderBeginFailure() throws {
        try database.performSyncThrowing { db in
            _ = sqlite3_exec(db, "PRAGMA busy_timeout = 50", nil, nil, nil)
            let thread = try SQLiteStatement(
                db: db,
                sql: "INSERT INTO quick_assist_threads (id, created_at, updated_at, title) VALUES ('t1', 1, 1, 'Thread')"
            )
            try thread.executeStep()
        }

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        // With a writer holding the file, BEGIN fails and nothing is deleted.
        database.deleteQuickAssistThread(threadId: "t1")

        sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)

        let survivingThreads = try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM quick_assist_threads WHERE id = 't1'")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
        XCTAssertEqual(survivingThreads, 1, "A failed begin must leave the thread fully intact")

        // With the blocker gone the same call deletes cleanly.
        database.deleteQuickAssistThread(threadId: "t1")
        let remaining = try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM quick_assist_threads WHERE id = 't1'")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
        XCTAssertEqual(remaining, 0)
    }

    private func readCreatedAt(sessionId: String) throws -> Int64 {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT created_at FROM sessions WHERE id = ?")
            query.bindText(sessionId, at: 1)
            guard try query.stepRow() else {
                throw DatabaseError.batchFailed(operation: "readCreatedAt: no row")
            }
            return query.columnInt64(0)
        }
    }
}
