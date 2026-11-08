import XCTest
import SQLite3
@testable import memanager

final class DatabaseMaintenanceServiceTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "maintenance-tests-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        defaults = UserDefaults(suiteName: "maintenance-tests-\(UUID().uuidString)")
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

    private func seedDebugEvents(count: Int, timestampMillis: Int64) throws {
        try database.performSyncThrowing { db in
            try database.withTransactionThrowing(db) {
                for index in 0..<count {
                    let insert = try SQLiteStatement(
                        db: db,
                        sql: """
                        INSERT INTO debug_events
                        (session_id, event_type, event_category, event_name, details, timestamp, created_at)
                        VALUES ('s', 'lifecycle', 'test', 'seeded-\(index)', NULL, ?, ?)
                        """
                    )
                    insert.bindInt64(timestampMillis, at: 1)
                    insert.bindInt64(timestampMillis, at: 2)
                    try insert.executeStep()
                }
            }
        }
    }

    private func debugEventCount() throws -> Int {
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM debug_events")
            _ = try query.stepRow()
            return query.columnInt(0)
        }
    }

    func testAgePruneRemovesOnlyExpiredRowsInBatches() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = RetentionPolicy(table: "debug_events", timestampColumn: "timestamp", maxAgeDays: 14, maxRows: 100_000)
        let expiredMillis = policy.ageCutoffMillis(now: now) - 1000
        let freshMillis = policy.ageCutoffMillis(now: now) + 1000

        // More than one batch of expired rows proves the batching loop drains fully.
        try seedDebugEvents(count: DatabaseMaintenanceService.batchSize + 200, timestampMillis: expiredMillis)
        try seedDebugEvents(count: 50, timestampMillis: freshMillis)

        let service = DatabaseMaintenanceService(database: database, policies: [policy], defaults: defaults)
        service.runOnce(now: now)

        XCTAssertEqual(try debugEventCount(), 50, "Expired rows pruned across batches; fresh rows untouched")
    }

    func testRowCapKeepsTheNewestRows() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = RetentionPolicy(table: "debug_events", timestampColumn: "timestamp", maxAgeDays: 3650, maxRows: 100)
        let base = Int64(now.timeIntervalSince1970 * 1000)

        for index in 0..<150 {
            try seedDebugEvents(count: 1, timestampMillis: base + Int64(index))
        }

        let service = DatabaseMaintenanceService(database: database, policies: [policy], defaults: defaults)
        service.runOnce(now: now)

        XCTAssertEqual(try debugEventCount(), 100)
        let oldestSurvivor = try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "SELECT MIN(timestamp) FROM debug_events")
            _ = try query.stepRow()
            return query.columnInt64(0)
        }
        XCTAssertEqual(oldestSurvivor, base + 50, "The oldest 50 rows must be the ones trimmed")
    }

    func testUserDataTablesAreNeverInDefaultPolicies() {
        let protected = ["sessions", "api_calls", "quick_assist_calls", "practice_cards",
                         "practice_reviews", "session_debriefs", "memory_nodes"]
        for policy in RetentionPolicy.defaults {
            XCTAssertFalse(protected.contains(policy.table), "\(policy.table) is user data and must never be auto pruned")
        }
    }
}

final class DebugEventSamplingPolicyStreamTests: XCTestCase {
    func testStreamSummaryEventsAlwaysPersist() {
        let policy = DebugEventSamplingPolicy()
        for name in ["stream_completed", "responses_stream_fallback_to_chat",
                     "responses_completed_without_visible_text", "visible_text_emitted"] {
            let decision = policy.decision(
                category: "openai_stream", name: name, type: "lifecycle", requestedIncludeMemory: false
            )
            XCTAssertTrue(decision.shouldPersist, "\(name) must always persist")
        }
    }

    func testUnlistedStreamEventsAreHeavilySampled() {
        let policy = DebugEventSamplingPolicy()
        let persisted = (0..<100).filter { _ in
            policy.decision(
                category: "openai_stream", name: "event_chatter", type: "lifecycle", requestedIncludeMemory: false
            ).shouldPersist
        }.count

        XCTAssertEqual(persisted, 2, "1 in 50 sampling over 100 events persists exactly 2")
    }
}

final class DebugNDJSONLoggerTests: XCTestCase {
    func testSensitiveKeysAreRedactedAndDebugKeysAreNot() {
        let logger = DebugNDJSONLogger(logFilePath: NSTemporaryDirectory() + "redact.log", rotationThresholdBytes: 1_000_000)

        let sanitized = logger.sanitize([
            "apiKey": "sk-super-secret",
            "authorization": "Bearer abc",
            "refresh_token": "tok",
            "key": "value",
            "hotkey": "cmd+shift+y",
            "keycode": 42
        ]) as? [String: Any]

        XCTAssertEqual(sanitized?["apiKey"] as? String, "<redacted>")
        XCTAssertEqual(sanitized?["authorization"] as? String, "<redacted>")
        XCTAssertEqual(sanitized?["refresh_token"] as? String, "<redacted>")
        XCTAssertEqual(sanitized?["key"] as? String, "<redacted>")
        XCTAssertEqual(sanitized?["hotkey"] as? String, "cmd+shift+y", "Debug fields stay readable")
        XCTAssertEqual(sanitized?["keycode"] as? Int, 42)
    }

    func testRotationMovesOversizedFileToBackup() throws {
        let path = NSTemporaryDirectory() + "rotation-\(UUID().uuidString).log"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".1")
        }
        let logger = DebugNDJSONLogger(logFilePath: path, rotationThresholdBytes: 200)

        for index in 0..<10 {
            logger.log(runId: "r", hypothesisId: "h", location: "test", message: "line \(index) padding padding padding")
        }
        logger.drain()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"), "Backup must exist after crossing the threshold")
        let currentSize = (try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int ?? 0
        XCTAssertLessThan(currentSize, 400, "Current file restarts small after rotation")
    }
}
