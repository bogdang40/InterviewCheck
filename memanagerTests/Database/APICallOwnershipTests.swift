import XCTest
@testable import memanager

final class APICallOwnershipTests: XCTestCase {
    private var directory: URL!
    private var database: SessionDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TestRuntime.temporaryDirectory.appendingPathComponent("api-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("sessions.sqlite").path)
    }

    override func tearDownWithError() throws {
        database?.flush()
        database = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testDeletedSessionRejectsLateSolveAndDesignTerminalCallbacks() throws {
        for type in ["solve", "system_design"] {
            seedSession("s")
            let cancelled = tracker(callType: type)
            let succeeded = tracker(callType: type)
            let failed = tracker(callType: type)
            try database.deleteSession(id: "s")
            cancelled.cancel()
            succeeded.complete(responsePayload: "Late answer")
            failed.fail(error: CancellationError())
        }
        database.flush()
        XCTAssertNil(database.getSessionRecord(id: "s"))
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "s").isEmpty)
        XCTAssertEqual(statCallCount, 0)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testReusedSessionIDDoesNotAdmitPreviousRequest() throws {
        seedSession("s")
        let old = tracker()
        try database.deleteSession(id: "s")
        seedSession("s")
        let replacement = tracker()
        old.cancel()
        replacement.complete(responsePayload: "Replacement")
        database.flush()

        let calls = database.getAPICallsForSession(sessionId: "s")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try storedResponsePayloads(), ["Replacement"])
        XCTAssertEqual(statCallCount, 1)
        XCTAssertNotNil(database.getSessionRecord(id: "s"))
    }

    func testUnrelatedSessionOwnershipSurvivesDeletion() throws {
        seedSession("removed")
        seedSession("kept")
        let removed = tracker(sessionId: "removed")
        let kept = tracker(sessionId: "kept")
        try database.deleteSession(id: "removed")
        removed.fail(error: CancellationError())
        kept.cancel()
        database.flush()
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "removed").isEmpty)
        XCTAssertEqual(database.getAPICallsForSession(sessionId: "kept").first?.status, "cancelled")
        XCTAssertEqual(statCallCount, 1)
    }

    func testThreadHistoryDeletionDoesNotCancelAPIOwnership() {
        let request = tracker()
        database.createQuickAssistThread(threadId: "thread", originSessionId: "s")
        database.deleteAllQuickAssistHistory()
        request.complete(responsePayload: "Solve answer")
        database.flush()
        XCTAssertEqual(database.getAPICallsForSession(sessionId: "s").count, 1)
        XCTAssertEqual(statCallCount, 1)
    }

    func testRolledBackSessionBatchDeletionPreservesEveryOwner() throws {
        for id in ["a", "z"] { seedSession(id) }
        let first = tracker(sessionId: "a")
        let last = tracker(sessionId: "z")
        try sql("CREATE TRIGGER reject_delete BEFORE DELETE ON sessions WHEN OLD.id = 'z' BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        XCTAssertThrowsError(try database.deleteSessions(ids: ["a", "z"]))
        first.cancel()
        last.complete(responsePayload: "Surviving answer")
        database.flush()
        for id in ["a", "z"] {
            XCTAssertNotNil(database.getSessionRecord(id: id))
            XCTAssertEqual(database.getAPICallsForSession(sessionId: id).count, 1)
        }
        XCTAssertEqual(statCallCount, 2)
    }

    func testQueuedTerminalBeforeDeletionIsRemovedWithoutRecountingStats() throws {
        seedSession("s")
        let request = tracker()
        // insertAPICall enqueues first; the synchronous deletion follows it
        // on the same queue and must remove that recorded terminal call.
        request.complete(responsePayload: "Recorded before deletion")
        try database.deleteSession(id: "s")
        database.flush()
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "s").isEmpty)
        XCTAssertNil(database.getSessionRecord(id: "s"))
        // Provider totals intentionally retain previously recorded usage.
        XCTAssertEqual(statCallCount, 1)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testQueuedOwnershipReleaseRunsBeforeLaterTerminalInsert() {
        let call = record().withCompletion(status: "cancelled")
        let ownership = database.registerAPICallOwnership(sessionId: call.sessionId)
        database.releaseAPICallOwnership(ownership)
        database.insertAPICall(call, ownershipID: ownership)
        database.flush()
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "s").isEmpty)
        XCTAssertEqual(statCallCount, 0)
    }

    func testReleasingTrackerImmediatelyAfterCompletionKeepsQueuedWrite() throws {
        do {
            let request = tracker()
            request.complete(responsePayload: "Saved")
        }
        database.flush()
        XCTAssertEqual(try storedResponsePayloads(), ["Saved"])
        XCTAssertEqual(statCallCount, 1)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testAbandonedTrackerReleasesOwnershipWithoutPendingHistory() {
        var request: APICallTracker? = tracker()
        XCTAssertNotNil(request)
        XCTAssertEqual(activeOwnershipCount, 1)
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "s").isEmpty)
        request = nil
        database.flush()
        XCTAssertEqual(activeOwnershipCount, 0)
        XCTAssertEqual(statCallCount, 0)
    }

    func testCompletionThenFinalizationFailureRecordsOneSuccessfulCall() throws {
        let request = tracker(callType: "system_design")
        request.complete(responsePayload: "Design response")
        request.fail(error: CancellationError())
        request.cancel()
        database.flush()
        let calls = database.getAPICallsForSession(sessionId: "s")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.status, "success")
        XCTAssertEqual(try storedResponsePayloads(), ["Design response"])
        let stats = try XCTUnwrap(database.getProviderStats().first)
        XCTAssertEqual(stats.callCount, 1)
        XCTAssertEqual(stats.successCount, 1)
        XCTAssertEqual(stats.errorCount, 0)
    }

    func testDirectInsertWithoutOwnershipStillRecordsAfterDeletion() throws {
        seedSession("s")
        let discarded = tracker()
        try database.deleteSession(id: "s")
        database.insertAPICall(record().withCompletion(status: "success", responsePayload: "Direct recording"))
        discarded.cancel()
        database.flush()
        let calls = database.getAPICallsForSession(sessionId: "s")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try storedResponsePayloads(), ["Direct recording"])
        XCTAssertEqual(statCallCount, 1)
    }

    func testOwnershipCannotBeConsumedForAnotherSessionOrUsedTwice() {
        let ownership = database.registerAPICallOwnership(sessionId: "s")
        database.insertAPICall(record(sessionId: "other"), ownershipID: ownership)
        let call = record().withCompletion(status: "cancelled")
        database.insertAPICall(call, ownershipID: ownership)
        database.insertAPICall(call, ownershipID: ownership)
        database.flush()
        XCTAssertTrue(database.getAPICallsForSession(sessionId: "other").isEmpty)
        XCTAssertEqual(database.getAPICallsForSession(sessionId: "s").count, 1)
        XCTAssertEqual(statCallCount, 1)
    }

    func testFailedPreparationDoesNotIncrementExistingProviderStats() throws {
        seedRecordedCall()
        try sql("DROP TABLE api_calls")
        let request = tracker()
        request.complete(responsePayload: "Cannot insert")
        database.flush()
        XCTAssertEqual(statCallCount, 1)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testFailedInsertionDoesNotIncrementExistingProviderStats() throws {
        seedRecordedCall()
        try sql("CREATE TRIGGER reject_insert BEFORE INSERT ON api_calls BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        let request = tracker()
        request.fail(error: CancellationError())
        database.flush()
        XCTAssertEqual(database.getAPICallsForSession(sessionId: "s").count, 1)
        XCTAssertEqual(statCallCount, 1)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testIgnoredInsertionDoesNotIncrementExistingProviderStats() throws {
        seedRecordedCall()
        try sql("CREATE TRIGGER ignore_insert BEFORE INSERT ON api_calls BEGIN SELECT RAISE(IGNORE); END")
        let request = tracker()
        request.cancel()
        database.flush()
        XCTAssertEqual(database.getAPICallsForSession(sessionId: "s").count, 1)
        XCTAssertEqual(statCallCount, 1)
    }

    private var statCallCount: Int {
        database.getProviderStats().reduce(0) { $0 + $1.callCount }
    }

    private var activeOwnershipCount: Int {
        database.performSync { _ in database.apiCallOwners.count }
    }

    private func storedResponsePayloads(sessionId: String = "s") throws -> [String?] {
        // The public history query projects metadata without payloads. Inspect
        // storage directly, retaining NULL rows so missing payloads still fail.
        try database.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: """
                SELECT response_payload FROM api_calls
                WHERE session_id = ? ORDER BY started_at DESC, id DESC
                """)
            query.bindText(sessionId, at: 1)
            var payloads: [String?] = []
            while try query.stepRow() { payloads.append(query.columnText(0)) }
            return payloads
        }
    }

    private func seedSession(_ id: String) {
        database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
    }

    private func seedRecordedCall() {
        database.insertAPICall(record().withCompletion(status: "success", responsePayload: "Saved"))
        database.flush()
    }

    private func record(sessionId: String = "s", callType: String = "solve") -> APICallRecord {
        APICallRecord(sessionId: sessionId, callType: callType, provider: "fixture", model: "fixture")
    }

    private func tracker(sessionId: String = "s", callType: String = "solve") -> APICallTracker {
        APICallTracker(record: record(sessionId: sessionId, callType: callType), database: database)
    }

    private func sql(_ statement: String) throws {
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: statement).executeStep()
        }
    }
}
