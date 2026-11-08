import XCTest
@testable import memanager

final class QuickAssistCallOwnershipTests: XCTestCase {
    private var directory: URL!
    private var database: SessionDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TestRuntime.temporaryDirectory.appendingPathComponent("call-ownership-\(UUID().uuidString)")
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

    func testCancelAfterThreadBatchDeletionCannotRecreateHistory() throws {
        database.createQuickAssistThread(threadId: "t")
        let request = tracker()
        try database.deleteQuickAssistThreads(ids: ["t"])
        request.cancel()
        assertEmptyHistory()
    }

    func testSingleThreadDeletionRejectsEveryTerminalCallback() {
        database.createQuickAssistThread(threadId: "t")
        let cancelled = tracker()
        let failed = tracker()
        let succeeded = tracker()
        database.deleteQuickAssistThread(threadId: "t")
        cancelled.cancel()
        failed.fail(error: CancellationError())
        succeeded.complete(responseText: "Late answer")
        assertEmptyHistory()
    }

    func testDeleteAllInvalidatesRequestsWithoutPersistedThreads() {
        let first = tracker(threadId: "first")
        let second = tracker(threadId: "second")
        database.deleteAllQuickAssistHistory()
        first.complete(responseText: "Late answer")
        second.cancel()
        assertEmptyHistory()
    }

    func testReusingDeletedThreadIDDoesNotAdmitOldCallback() throws {
        database.createQuickAssistThread(threadId: "t")
        let old = tracker(turnId: "old")
        try database.deleteQuickAssistThreads(ids: ["t"])
        let replacement = tracker(turnId: "replacement")
        replacement.complete(responseText: "New answer")
        old.cancel()

        let calls = database.getRecentQuickAssistCalls()
        XCTAssertEqual(calls.map(\.turnId), ["replacement"])
        XCTAssertEqual(calls.first?.responseText, "New answer")
        XCTAssertEqual(database.getQuickAssistThreads().map(\.id), ["t"])
    }

    func testSessionDeletionKeepsOtherSessionRequestInSharedThread() throws {
        for id in ["first", "second"] {
            database.insertSession(SessionRecord(id: id, startedAt: Date(), state: "ended"))
            database.insertQuickAssistCall(record(sessionId: id, turnId: "saved-\(id)").withCompletion(
                status: "success", responseText: "Saved answer"
            ))
        }
        let removed = tracker(sessionId: "first", turnId: "removed")
        let surviving = tracker(sessionId: "second", turnId: "surviving")
        try database.deleteSession(id: "first")
        removed.cancel()
        surviving.complete(responseText: "Follow up")

        XCTAssertNil(database.getSessionRecord(id: "first"))
        XCTAssertTrue(database.getQuickAssistCallsForSession(sessionId: "first").isEmpty)
        XCTAssertEqual(Set(database.getRecentQuickAssistCalls().map(\.turnId)), ["saved-second", "surviving"])
        XCTAssertEqual(database.getQuickAssistThreads().first?.originSessionId, "second")
    }

    func testSessionDeletionInvalidatesRequestInRemovedEmptyThread() throws {
        database.insertSession(SessionRecord(id: "first", startedAt: Date(), state: "ended"))
        database.createQuickAssistThread(threadId: "t", originSessionId: "first")
        let requestFromAnotherSession = tracker(sessionId: "second")
        try database.deleteSession(id: "first")
        requestFromAnotherSession.cancel()
        assertEmptyHistory()
    }

    func testUnrelatedThreadDeletionKeepsCancelledAuditRecord() throws {
        database.createQuickAssistThread(threadId: "t")
        database.createQuickAssistThread(threadId: "unrelated")
        let request = tracker(turnId: "kept")
        try database.deleteQuickAssistThreads(ids: ["unrelated"])
        request.cancel()
        XCTAssertEqual(database.getRecentQuickAssistCalls().map(\.turnId), ["kept"])
        XCTAssertEqual(database.getRecentQuickAssistCalls().first?.status, "cancelled")
    }

    func testFailedBatchDeletionPreservesEveryRequestOwnership() throws {
        for id in ["a", "z"] { database.createQuickAssistThread(threadId: id) }
        let first = tracker(threadId: "a")
        let last = tracker(threadId: "z")
        try installRejection("quick_assist_threads", predicate: "OLD.id = 'z'")
        XCTAssertThrowsError(try database.deleteQuickAssistThreads(ids: ["a", "z"]))
        first.cancel()
        last.cancel()
        XCTAssertEqual(Set(database.getRecentQuickAssistCalls().map(\.threadId)), ["a", "z"])
    }

    func testFailedSingleAndAllThreadDeletionPreserveOwnership() throws {
        database.createQuickAssistThread(threadId: "t")
        let single = tracker(turnId: "single")
        try installRejection("quick_assist_threads")
        database.deleteQuickAssistThread(threadId: "t")
        single.cancel()
        let all = tracker(turnId: "all")
        database.deleteAllQuickAssistHistory()
        all.cancel()
        XCTAssertEqual(Set(database.getRecentQuickAssistCalls().map(\.turnId)), ["single", "all"])
    }

    func testFailedSessionDeletionPreservesOwnershipInRolledBackEmptyThread() throws {
        database.insertSession(SessionRecord(id: "first", startedAt: Date(), state: "ended"))
        database.createQuickAssistThread(threadId: "t", originSessionId: "first")
        let request = tracker(sessionId: "second")
        try installRejection("sessions")
        XCTAssertThrowsError(try database.deleteSession(id: "first"))
        request.cancel()
        XCTAssertEqual(database.getRecentQuickAssistCalls().first?.status, "cancelled")
        XCTAssertNotNil(database.getSessionRecord(id: "first"))
    }

    func testCancelledRequestWritesOneTerminalAuditWithoutPendingHistory() throws {
        let request = tracker()
        assertEmptyHistory()
        request.cancel()
        request.fail(error: CancellationError())
        request.complete(responseText: "Ignored")
        let calls = database.getRecentQuickAssistCalls()
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.status, "cancelled")
        XCTAssertEqual(call.verificationStatus, .failed)
        XCTAssertNotNil(call.completedAt)
        XCTAssertNil(call.responseText)
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    func testFirstTrackedCallWithoutPersistedParentsCreatesHistory() {
        let request = tracker()
        request.complete(responseText: "Guarded", rawResponseText: "Raw", resolvedQuestion: "Resolved")
        let call = database.getRecentQuickAssistCalls().first
        XCTAssertEqual(call?.responseText, "Guarded")
        XCTAssertEqual(call?.rawResponseText, "Raw")
        XCTAssertEqual(call?.question, "Resolved")
        XCTAssertEqual(database.getQuickAssistThreads().map(\.id), ["t"])
        XCTAssertNil(database.getSessionRecord(id: "s"))
    }

    func testDirectRecordingStillCreatesThreadAfterDeletion() throws {
        let discarded = tracker(turnId: "discarded")
        try database.deleteQuickAssistThreads(ids: ["t"])
        database.insertQuickAssistCall(record(turnId: "copied").withCompletion(status: "success", responseText: "Copy"))
        discarded.cancel()
        XCTAssertEqual(database.getRecentQuickAssistCalls().map(\.turnId), ["copied"])
        XCTAssertEqual(database.getQuickAssistThreads().map(\.id), ["t"])
    }

    func testAbandonedTrackerReleasesOwnershipWithoutHistory() {
        var request: QuickAssistCallTracker? = tracker()
        XCTAssertNotNil(request)
        XCTAssertEqual(activeOwnershipCount, 1)
        request = nil
        database.flush()
        XCTAssertEqual(activeOwnershipCount, 0)
        assertEmptyHistory()
    }

    func testOwnershipCannotBeConsumedByAnotherTurnOrUsedTwice() {
        let original = record(turnId: "original").withCompletion(status: "success", responseText: "Saved")
        let ownership = database.registerQuickAssistCallOwnership(original)
        database.insertQuickAssistCall(record(turnId: "other"), ownershipID: ownership)
        XCTAssertEqual(activeOwnershipCount, 1)
        assertEmptyHistory()
        database.insertQuickAssistCall(original, ownershipID: ownership)
        database.insertQuickAssistCall(original, ownershipID: ownership)
        XCTAssertEqual(database.getRecentQuickAssistCalls().map(\.turnId), ["original"])
        XCTAssertEqual(activeOwnershipCount, 0)
    }

    private var activeOwnershipCount: Int {
        database.performSync { _ in database.quickAssistCallOwners.count }
    }

    private func record(sessionId: String = "s", threadId: String = "t", turnId: String = UUID().uuidString) -> QuickAssistCallRecord {
        QuickAssistCallRecord(sessionId: sessionId, threadId: threadId, turnId: turnId, provider: "fixture", model: "fixture")
    }

    private func tracker(sessionId: String = "s", threadId: String = "t", turnId: String = UUID().uuidString) -> QuickAssistCallTracker {
        QuickAssistCallTracker(record: record(sessionId: sessionId, threadId: threadId, turnId: turnId), database: database)
    }

    private func installRejection(_ table: String, predicate: String = "1") throws {
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON \(table) WHEN \(predicate) BEGIN SELECT RAISE(ABORT, 'deletion blocked'); END").executeStep()
        }
    }

    private func assertEmptyHistory(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(database.getRecentQuickAssistCalls().isEmpty, file: file, line: line)
        XCTAssertTrue(database.getQuickAssistThreads().isEmpty, file: file, line: line)
    }
}
