import SQLite3
import XCTest
@testable import memanager

final class SessionDatabaseLifetimeTests: XCTestCase {
    func testFinalAsyncOwnerCanReleaseOnDatabaseQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var database: SessionDatabase? = SessionDatabase(databasePath: directory.appendingPathComponent("lifetime.sqlite").path)
        weak var weakDatabase = database
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let completed = expectation(description: "queued writer completed")

        database?.performAsync { [retained = database] connection in
            started.signal()
            _ = finish.wait(timeout: .now() + 2)
            XCTAssertNotNil(connection)
            withExtendedLifetime(retained) { completed.fulfill() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        database = nil
        finish.signal()
        wait(for: [completed], timeout: 2)

        let released = expectation(for: NSPredicate { _, _ in weakDatabase == nil }, evaluatedWith: nil)
        wait(for: [released], timeout: 2)
    }

    func testQueuedWriteKeepsConnectionAfterExternalOwnerReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lifetime.sqlite").path
        var database: SessionDatabase? = SessionDatabase(databasePath: path)
        weak var weakDatabase = database
        let gate = DispatchSemaphore(value: 0)
        database?.performAsync { _ in _ = gate.wait(timeout: .now() + 2) }
        database?.insertTranscriptEntry(TranscriptEntryRecord(sessionId: "session", speaker: "user", text: "kept"))

        // Also lets the previous implementation's synchronous teardown drain
        // without blocking the test indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        database = nil
        let released = expectation(for: NSPredicate { _, _ in weakDatabase == nil }, evaluatedWith: nil)
        wait(for: [released], timeout: 2)

        let reopened = SessionDatabase(databasePath: path)
        XCTAssertEqual(reopened.getTranscriptEntries(sessionId: "session").map(\.text), ["kept"])
    }
}
