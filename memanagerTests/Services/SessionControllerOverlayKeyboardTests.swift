import XCTest
@testable import memanager

@MainActor
final class SessionControllerOverlayKeyboardTests: SessionControllerDatabaseTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        controller.activeScrollTarget = .main
        controller.isQuickAssistViewVisible = true
        controller.isTranscriptViewVisible = false
        controller.isMLGuideViewVisible = false
        controller.quickAssistQuestion = ""
        controller.quickAssistExtraContext = ""
        controller.quickAssistExtraContextExpanded = false
        controller.quickAssistHistorySearchQuery = ""
        controller.quickAssistPendingDeletionThreadID = nil
        controller.quickAssistSelectedHistoryThreadID = "thread-1"
        controller.activeQuickAssistThreadID = "thread-1"
        controller.quickAssistThreadSummaries = [
            QuickAssistThreadSummary(
                id: "thread-1",
                title: "Example Thread",
                createdAt: Date(),
                updatedAt: Date(),
                originSessionId: nil,
                parentThreadId: nil,
                branchedFromTurnId: nil,
                turnCount: 1,
                lastTurnAt: Date(),
                previewText: "Preview"
            )
        ]
        controller.quickAssistRelatedMemorySnippets = [
            RelatedMemorySnippet(
                id: "memory-1",
                text: "Pinned candidate",
                sourceType: .quickAssist,
                sourceRef: nil,
                threadId: nil,
                turnId: nil,
                score: 0.8,
                reasons: [.threadMatch],
                relationType: nil,
                isPinned: false
            )
        ]
        controller.setOverlayWindowVisible(true)
    }

    func testModeKeyboardSelectionSurvivesMultipleArrowsAndActivation() {
        let modes = QuickAssistThreadMode.allCases
        controller.setQuickAssistThreadMode(modes[0])
        controller.overlayFocusTarget = .quickAssistRouteOverride
        controller.overlaySelectionState.routeOverrideIndex = 0

        XCTAssertTrue(controller.handleOverlayCommand(.moveRight))
        XCTAssertTrue(controller.handleOverlayCommand(.moveRight))
        XCTAssertEqual(controller.overlaySelectionState.routeOverrideIndex, 2)
        XCTAssertTrue(controller.handleOverlayCommand(.activate))
        XCTAssertEqual(controller.quickAssistSelectedMode, modes[2])
    }

    func testInsertTextWritesIntoQuickAssistQuestionWhenFocused() {
        controller.overlayFocusTarget = .quickAssistQuestion

        XCTAssertTrue(controller.handleOverlayCommand(.insertText("h")))
        XCTAssertTrue(controller.handleOverlayCommand(.insertText("i")))

        XCTAssertEqual(controller.quickAssistQuestion, "hi")
    }

    func testDeleteSelectionPromptsForHistoryDeletion() {
        controller.overlayFocusTarget = .quickAssistHistoryThreads

        XCTAssertTrue(controller.handleOverlayCommand(.deleteSelection))
        XCTAssertEqual(controller.quickAssistPendingDeletionThreadID, "thread-1")
    }

    func testActivatePinsSelectedRelatedMemory() {
        controller.overlayFocusTarget = .quickAssistRelatedMemory

        XCTAssertTrue(controller.handleOverlayCommand(.activate))
        XCTAssertTrue(controller.quickAssistRelatedMemorySnippets[0].isPinned)
    }

    func testPreferredHotkeyScrollTargetPrefersQuickAssistWhenResponseVisible() {
        controller.quickAssistResponse = "A visible Quick Assist answer"
        controller.activeScrollTarget = .main

        XCTAssertEqual(controller.preferredHotkeyScrollTarget, .quickAssist)
    }

    func testPreferredHotkeyScrollTargetPreservesTranscriptOverride() {
        controller.quickAssistResponse = "A visible Quick Assist answer"
        controller.isTranscriptViewVisible = true

        XCTAssertEqual(controller.preferredHotkeyScrollTarget, .transcript)
    }

    func testSelectingHistoryThreadMovesOverlayFocusToHistoryList() {
        controller.overlayFocusTarget = .quickAssistHistorySearch

        controller.selectNextQuickAssistHistoryThread()

        XCTAssertEqual(controller.overlayFocusTarget, .quickAssistHistoryThreads)
    }
}
