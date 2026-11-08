import XCTest
@testable import memanager

final class QuickAssistThreadQueryTests: XCTestCase {
    func testIdentityQueryIncludesThreadsBeyondLoadedHistoryLimit() throws {
        let database = SessionDatabase(databasePath: ":memory:")
        let ids = Set((0..<305).map { "thread-\($0)" })
        for id in ids { database.createQuickAssistThread(threadId: id) }

        XCTAssertEqual(database.getQuickAssistThreads(limit: 300).count, 300)
        XCTAssertEqual(try database.getQuickAssistThreadIDs(), ids)
        XCTAssertEqual(try database.getQuickAssistThreadIDs(), ids, "Confirmation reads must not change history")
    }

    func testIdentityQueryReturnsEmptyWithoutCreatingAPlaceholder() throws {
        let database = SessionDatabase(databasePath: ":memory:")
        XCTAssertTrue(try database.getQuickAssistThreadIDs().isEmpty)
        XCTAssertTrue(database.getQuickAssistThreads().isEmpty)
    }

    func testIdentityQueryPropagatesReadFailure() throws {
        let database = SessionDatabase(databasePath: ":memory:")
        try database.performSyncThrowing { db in
            try SQLiteStatement(db: db, sql: "DROP TABLE quick_assist_threads").executeStep()
        }
        XCTAssertThrowsError(try database.getQuickAssistThreadIDs())
    }

    func testCapturedDeletionPreservesThreadInsertedAfterFinalValidation() throws {
        let database = SessionDatabase(databasePath: ":memory:")
        database.createQuickAssistThread(threadId: "captured")
        let confirmation = try XCTUnwrap(HistoryBatchDeletionConfirmation(
            allIDs: database.getQuickAssistThreadIDs()
        ))
        let capturedIDs = try XCTUnwrap(confirmation.validatedAllIDs(
            currentIDs: database.getQuickAssistThreadIDs(), deletionEnabled: true
        ))

        database.createQuickAssistThread(threadId: "created-after-validation")
        try database.deleteQuickAssistThreads(ids: capturedIDs)

        XCTAssertEqual(try database.getQuickAssistThreadIDs(), ["created-after-validation"])
    }
}
