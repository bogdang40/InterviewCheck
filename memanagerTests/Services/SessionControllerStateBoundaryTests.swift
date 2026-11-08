import XCTest
@testable import memanager

@MainActor
final class SessionControllerStateBoundaryTests: SessionControllerDatabaseTestCase {
    func testInterruptedFirstAnswerRemainsScrollable() {
        controller.isQuickAssistViewVisible = true
        controller.activeScrollTarget = .main
        controller.quickAssistInterruptedAnswer = QuickAssistInterruptedAnswer(
            response: "Retained partial answer", question: "Question", reason: .failed
        )
        XCTAssertTrue(controller.hasQuickAssistScrollableContent)
        XCTAssertEqual(controller.preferredHotkeyScrollTarget, .quickAssist)
    }

    func testHistorySynchronizationRepairsNegativeSelection() {
        let turn = QuickAssistThread.Turn(
            id: UUID(), timestamp: Date(), transcriptDelta: "", question: "Question",
            response: "Answer", contextMode: .conversation, modelTier: .fast
        )
        controller.quickAssistCoordinator.activateThread(id: "fixture", turns: [turn])
        controller.selectedQuickAssistTurnIndex = -1
        controller.syncQuickAssistTurnsFromCoordinator(selectNewest: false)
        XCTAssertEqual(controller.selectedQuickAssistTurnIndex, 0)
        XCTAssertEqual(controller.selectedQuickAssistTurn?.id, turn.id)
        XCTAssertEqual(controller.quickAssistResponse, "Answer")
    }

    func testCancelledSolveCannotPublishIntoReplacementRequest() {
        let sessionID = controller.session.id
        let oldRequestID = UUID()
        controller.activeSolveRequestID = oldRequestID
        controller.isLoading = true
        controller.isStreaming = true
        XCTAssertTrue(controller.applySolveStreamChunk("## Problem\nOriginal", sessionID: sessionID, requestID: oldRequestID))

        controller.cancelActiveRequest()
        let newRequestID = UUID()
        controller.activeSolveRequestID = newRequestID
        controller.isLoading = true
        controller.isStreaming = true
        controller.streamingResponseText = "Replacement"

        XCTAssertFalse(controller.applySolveStreamChunk(" stale", sessionID: sessionID, requestID: oldRequestID))
        XCTAssertFalse(controller.applySystemDesignStreamText("stale design", sessionID: sessionID, requestID: oldRequestID))
        XCTAssertEqual(controller.streamingResponseText, "Replacement")
        XCTAssertTrue(controller.applySystemDesignStreamText("Current", sessionID: sessionID, requestID: newRequestID))
        XCTAssertEqual(controller.streamingResponseText, "Current")
    }

    func testCompletedRequestRejectsDelayedStreamPublication() {
        let requestID = UUID()
        controller.activeSolveRequestID = requestID
        controller.isLoading = false
        controller.isStreaming = false
        controller.streamingResponseText = "Settled"

        XCTAssertFalse(controller.applySolveStreamChunk("late chunk", sessionID: controller.session.id, requestID: requestID))
        XCTAssertFalse(controller.applySystemDesignStreamText("late design", sessionID: controller.session.id, requestID: requestID))
        XCTAssertEqual(controller.streamingResponseText, "Settled")
    }

    func testResetClearsStreamCanvasAndNavigationProjection() {
        let oldSessionID = controller.session.id
        let oldRequestID = controller.activeSolveRequestID
        controller.isStreaming = true
        controller.isLoading = true
        controller.streamingResponseText = "Old answer"
        controller.currentChunkIndex = 8
        controller.totalChunkCount = 9
        controller.quickAssistPendingDeletionThreadID = "old-thread"
        controller.canvasScene = .empty.applying(.array(CanvasArrayPayload(id: "old", values: ["1"], label: "Old")))

        controller.resetSessionStateForTesting()

        XCTAssertNotEqual(controller.session.id, oldSessionID)
        XCTAssertNotEqual(controller.activeSolveRequestID, oldRequestID)
        XCTAssertFalse(controller.isStreaming)
        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(controller.streamingResponseText, "")
        XCTAssertEqual(controller.currentChunkIndex, 0)
        XCTAssertEqual(controller.totalChunkCount, 0)
        XCTAssertEqual(controller.canvasScene, .empty)
        XCTAssertNil(controller.quickAssistPendingDeletionThreadID)
        XCTAssertFalse(controller.applySystemDesignStreamText("old answer", sessionID: oldSessionID, requestID: oldRequestID))
    }

    func testEmptyAndNegativeNavigationCountsClampSelection() {
        controller.currentChunkIndex = 6
        controller.setChunkCount(0)
        XCTAssertEqual(controller.currentChunkIndex, 0)
        controller.currentChunkIndex = -2
        controller.setChunkCount(-3)
        XCTAssertEqual(controller.totalChunkCount, 0)
        XCTAssertEqual(controller.currentChunkIndex, 0)

        controller.expandedImplementationStep = 5
        controller.setImplementationStepCount(0)
        XCTAssertEqual(controller.expandedImplementationStep, 1)
        controller.setImplementationStepCount(-2)
        XCTAssertEqual(controller.implementationStepCount, 0)
        controller.setSystemDesignSectionCount(-4)
        XCTAssertEqual(controller.systemDesignSectionCount, 0)
        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
    }

    func testInjectedDebriefComposerSurvivesProviderReload() async {
        let composed = expectation(description: "Injected composer used")
        let composer = BoundaryDebriefComposer { composed.fulfill() }
        controller = SessionController(
            workstreamTimelineRepository: WorkstreamTimelineRepository(logger: logger),
            relatedMemoryService: RelatedMemoryService(logger: logger),
            debriefComposer: composer, logger: logger
        )
        controller.reloadProvider()
        controller.generateSessionDebrief()
        await fulfillment(of: [composed], timeout: 1)
    }
}

private struct BoundaryDebriefComposer: SessionDebriefComposing {
    let didCompose: () -> Void

    func compose(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String?
    ) async -> SessionDebrief? {
        didCompose()
        return nil
    }
}
