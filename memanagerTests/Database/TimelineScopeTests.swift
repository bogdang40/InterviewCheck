import XCTest
@testable import memanager

final class TimelineScopeTests: XCTestCase {
    func testUnknownThreadDoesNotLoadUnrelatedSessionArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = SessionDatabase(databasePath: directory.appendingPathComponent("timeline.sqlite").path)
        database.insertSession(SessionRecord(id: "unrelated", startedAt: Date(), state: "ended"))
        database.insertTranscriptEntry(TranscriptEntryRecord(sessionId: "unrelated", speaker: "user", text: "session transcript"))
        database.insertScreenshot(ScreenshotRecord(sessionId: "unrelated", source: "manual"))
        database.upsertMemoryNode(MemoryNodeRecord(
            id: "unrelated-memory", sessionId: "unrelated", sourceType: .solve,
            sourceRef: nil, content: "session memory", summary: nil, tags: [],
            importance: 1, createdAt: Date(), updatedAt: Date()))
        database.insertDebugEvent(DebugEventRecord(
            sessionId: "unrelated", eventType: "error", eventCategory: "fixture", eventName: "fixture_error"))

        XCTAssertNotNil(database.getSessionRecord(id: "unrelated"))
        let sessionEvents = database.getWorkstreamTimeline(filter: WorkstreamTimelineFilter(sessionId: "unrelated"))
        XCTAssertTrue(sessionEvents.contains { $0.type == .transcript })
        XCTAssertTrue(sessionEvents.contains { $0.type == .screenshot })

        // Transcripts and screenshots require a session scope. Memory and
        // debug events are global when no session/thread filter is requested.
        let unfiltered = database.getWorkstreamTimeline(filter: WorkstreamTimelineFilter())
        XCTAssertTrue(unfiltered.contains { $0.type == .memory })
        XCTAssertTrue(unfiltered.contains { $0.type == .debug })

        let scoped = database.getWorkstreamTimeline(filter: WorkstreamTimelineFilter(threadId: "missing-thread"))
        XCTAssertTrue(scoped.isEmpty)
    }
}
