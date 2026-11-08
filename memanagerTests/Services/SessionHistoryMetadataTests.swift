import XCTest
@testable import memanager

@MainActor
final class SessionHistoryMetadataTests: SessionControllerDatabaseTestCase {
    func testOlderPageCannotReplaceNewerPageMetadataOrItsFilterResults() async {
        let old = seedSession(preview: "Old page")
        let current = seedSession(preview: "Current page")
        let oldQueue = DispatchQueue(label: "test.metadata.old")
        let currentQueue = DispatchQueue(label: "test.metadata.current")
        oldQueue.suspend()

        controller.loadSessionCardMetadata(sessions: [old], queue: oldQueue)
        controller.loadSessionCardMetadata(sessions: [current], queue: currentQueue)
        await drain(currentQueue)
        XCTAssertEqual(controller.sessionCardMetadataMap[current.id]?.debriefPreview, "Current page")

        oldQueue.resume()
        await drain(oldQueue)

        XCTAssertEqual(Set(controller.sessionCardMetadataMap.keys), [current.id])
        let resolver = SessionListResolver(filters: [.hasDebrief])
        XCTAssertEqual(resolver.apply(to: [current], metadata: controller.sessionCardMetadataMap).map(\.id), [current.id])
    }

    func testStartingPageFetchInvalidatesMetadataBeforeReplacementRowsArrive() async {
        let old = seedSession(preview: "Old page")
        let queue = DispatchQueue(label: "test.metadata.page-fetch")
        queue.suspend()
        controller.loadSessionCardMetadata(sessions: [old], queue: queue)

        // The replacement page is still loading, so no second metadata load
        // has started. Its predecessor must already have lost publication rights.
        controller.invalidateSessionCardMetadata()
        queue.resume()
        await drain(queue)
        XCTAssertTrue(controller.sessionCardMetadataMap.isEmpty)

        controller.loadSessionCardMetadata(sessions: [old], queue: queue)
        await drain(queue)
        XCTAssertEqual(controller.sessionCardMetadataMap[old.id]?.debriefPreview, "Old page")
    }

    func testSessionResetRejectsPendingMetadataPublication() async {
        let old = seedSession(preview: "Before reset")
        let queue = DispatchQueue(label: "test.metadata.reset")
        queue.suspend()
        controller.loadSessionCardMetadata(sessions: [old], queue: queue)
        controller.resetSessionStateForTesting()

        queue.resume()
        await drain(queue)
        XCTAssertTrue(controller.sessionCardMetadataMap.isEmpty)
        XCTAssertNotNil(database.getSessionRecord(id: old.id), "Reset must preserve historical data")
    }

    func testDeletionCannotRepopulateRemovedMetadataFromPendingRefresh() async {
        let deleted = seedSession(preview: "Remove this session")
        let retained = seedSession(preview: "Keep this session")
        let queue = DispatchQueue(label: "test.metadata.delete")
        controller.loadSessionCardMetadata(sessions: [deleted, retained], queue: queue)
        await drain(queue)
        XCTAssertEqual(controller.sessionCardMetadataMap.count, 2)

        queue.suspend()
        controller.loadSessionCardMetadata(sessions: [deleted, retained], queue: queue)
        XCTAssertNoThrow(try controller.deleteHistorySession(id: deleted.id))
        queue.resume()
        await drain(queue)

        XCTAssertEqual(Set(controller.sessionCardMetadataMap.keys), [retained.id])
        XCTAssertNil(database.getSessionRecord(id: deleted.id))
        XCTAssertEqual(controller.sessionCardMetadataMap[retained.id]?.debriefPreview, "Keep this session")
    }

    private func seedSession(preview: String) -> SessionRecord {
        let record = SessionRecord(id: UUID().uuidString, startedAt: Date(), state: "idle")
        database.insertSession(record)
        database.saveSessionDebrief(SessionDebrief(
            id: UUID().uuidString, sessionId: record.id, whatHappened: [preview],
            strongMoments: [], missedOpportunities: [], recommendedDrills: [],
            nextSessionFocus: [], createdAt: Date(), updatedAt: Date(), drills: []
        ))
        return record
    }

    /// The serial worker enqueues publication before this marker. Resuming on
    /// main therefore observes that publication without timing-based sleeps.
    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
