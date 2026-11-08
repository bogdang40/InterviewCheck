import XCTest
@testable import memanager

final class HistoryBatchDeletionConfirmationTests: XCTestCase {
    private let visible: Set<String> = ["selected", "other"]

    func testUnchangedConfirmationReturnsOnlyCapturedSelection() throws {
        let confirmation = try makeConfirmation()
        XCTAssertEqual(confirmation.validatedIDs(
            selection: selection(), visibleIDs: visible, deletionEnabled: true
        ), ["selected"])
    }

    func testClearDoneAndCheckboxChangesInvalidatePendingDeletion() throws {
        let confirmation = try makeConfirmation()
        var cleared = selection()
        cleared.ids = []
        var finished = selection()
        finished.finish()
        var changed = selection()
        changed.toggle("other")
        for selection in [cleared, finished, changed] {
            XCTAssertNil(confirmation.validatedIDs(
                selection: selection, visibleIDs: visible, deletionEnabled: true
            ))
        }
    }

    func testFinalValidationRejectsFilteredSelectionBeforeSelectionPruning() throws {
        let confirmation = try makeConfirmation()
        // The selection still contains the old ID, as it can before SwiftUI
        // delivers the eligibility onChange callback after a filter edit.
        XCTAssertNil(confirmation.validatedIDs(
            selection: selection(), visibleIDs: ["other"], deletionEnabled: true
        ))
    }

    func testScopeChangeInvalidatesEvenWhenSelectedThreadRemainsVisible() throws {
        let confirmation = try makeConfirmation()
        XCTAssertNil(confirmation.validatedIDs(
            selection: selection(), visibleIDs: ["selected", "replacement"], deletionEnabled: true
        ))
    }

    func testStartingGenerationInvalidatesPendingDeletion() throws {
        let confirmation = try makeConfirmation()
        XCTAssertNil(confirmation.validatedIDs(
            selection: selection(), visibleIDs: visible, deletionEnabled: false
        ))
    }

    func testCannotCaptureEmptyOrHiddenSelection() {
        XCTAssertNil(HistoryBatchDeletionConfirmation(selectedIDs: [], visibleIDs: visible))
        XCTAssertNil(HistoryBatchDeletionConfirmation(selectedIDs: ["hidden"], visibleIDs: visible))
    }

    func testAllThreadsConfirmationCapturesExactUniverseAndCount() throws {
        let ids = Set((0..<305).map { "thread-\($0)" })
        let confirmation = try XCTUnwrap(HistoryBatchDeletionConfirmation(allIDs: ids))
        XCTAssertEqual(confirmation.validatedAllIDs(currentIDs: ids, deletionEnabled: true), ids)
        let action = ThreadHistoryDeletionConfirmation.allThreads(confirmation).action
        XCTAssertEqual(action.message, "All 305 Quick Assist threads and their turns will be removed for good.")
    }

    func testAllThreadsFinalValidationRejectsNewRemovedOrReplacedThread() throws {
        let confirmation = try XCTUnwrap(HistoryBatchDeletionConfirmation(allIDs: visible))
        for currentIDs: Set<String> in [visible.union(["new"]), ["selected"], ["selected", "replacement"]] {
            XCTAssertNil(confirmation.validatedAllIDs(currentIDs: currentIDs, deletionEnabled: true))
        }
    }

    func testAllThreadsConfirmationCannotBeUsedForSelectionOrDuringGeneration() throws {
        let confirmation = try XCTUnwrap(HistoryBatchDeletionConfirmation(allIDs: visible))
        XCTAssertNil(confirmation.validatedAllIDs(currentIDs: visible, deletionEnabled: false))
        XCTAssertNil(confirmation.validatedIDs(
            selection: HistoryBatchSelection(isSelecting: true, ids: visible),
            visibleIDs: visible, deletionEnabled: true
        ))
        XCTAssertNil(try makeConfirmation().validatedAllIDs(currentIDs: ["selected"], deletionEnabled: true))
        XCTAssertNil(HistoryBatchDeletionConfirmation(allIDs: []))
    }

    func testSingleThreadConfirmationKeepsExplicitTitleAndName() {
        let summary = QuickAssistThreadSummary(
            id: "one", title: "Named thread", createdAt: Date(), updatedAt: Date(),
            originSessionId: nil, turnCount: 0, lastTurnAt: nil, previewText: nil
        )
        let action = ThreadHistoryDeletionConfirmation.thread(summary).action
        XCTAssertEqual(action.title, "Delete this thread?")
        XCTAssertEqual(action.message, "\"Named thread\" and all of its turns will be removed for good.")
    }

    private func selection() -> HistoryBatchSelection {
        HistoryBatchSelection(isSelecting: true, ids: ["selected"])
    }

    private func makeConfirmation() throws -> HistoryBatchDeletionConfirmation {
        try XCTUnwrap(HistoryBatchDeletionConfirmation(selectedIDs: ["selected"], visibleIDs: visible))
    }
}
