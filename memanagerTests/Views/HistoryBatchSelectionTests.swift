import XCTest
@testable import memanager

final class HistoryBatchSelectionTests: XCTestCase {
    func testFilteringRemovesHiddenAndProtectedSelections() {
        var selection = HistoryBatchSelection(isSelecting: true, ids: ["visible", "hidden", "active"])
        selection.retainEligible(["visible", "other"])
        XCTAssertEqual(selection.ids, ["visible"])
        selection.toggle("other")
        selection.toggle("visible")
        XCTAssertEqual(selection.ids, ["other"])
        selection.finish()
        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testMultipleDeletionSelectsFirstSurvivingNeighbour() {
        let visible = ["a", "b", "c", "d"]
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting(["b", "c"], selectedID: "b", visibleIDs: visible), "d")
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting(["b", "c", "d"], selectedID: "c", visibleIDs: visible), "a")
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting(["b", "c"], selectedID: "a", visibleIDs: visible), "a")
        XCTAssertNil(SessionListResolver.selectionAfterDeleting(Set(visible), selectedID: "b", visibleIDs: visible))
    }

    func testEmptySessionRequiresKnownMetadataAndNoEvidence() {
        var session = SessionRecord(id: "empty", startedAt: Date(), state: "ended")
        let metadata = SessionCardMetadata(id: session.id, verifiedCount: 0, needsReviewCount: 0, failedCount: 0, pendingCount: 0, threadCount: 1, dominantTier: .fast, debriefPreview: nil, hasCoachFindings: false)
        XCTAssertFalse(HistoryBatchSelection.emptySession(session, metadata: nil))
        XCTAssertTrue(HistoryBatchSelection.emptySession(session, metadata: metadata))
        session.transcript = "Useful transcript"
        XCTAssertFalse(HistoryBatchSelection.emptySession(session, metadata: metadata))
        session.transcript = nil
        session.hasResponse = true
        XCTAssertFalse(HistoryBatchSelection.emptySession(session, metadata: metadata))
    }
}
