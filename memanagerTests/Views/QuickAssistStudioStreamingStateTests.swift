import XCTest
@testable import memanager

final class QuickAssistStudioStreamingStateTests: XCTestCase {
    func testFocusRequestDefersUntilActiveAndDoesNotRepeatOnReturn() {
        var request = QuickAssistFocusRequest()
        XCTAssertFalse(request.consume(1, isActive: false))
        XCTAssertTrue(request.consume(1, isActive: true))
        XCTAssertFalse(request.consume(1, isActive: false))
        XCTAssertFalse(request.consume(1, isActive: true))
        XCTAssertTrue(request.consume(2, isActive: true))
    }

    func testFocusRequestResetAllowsFirstRequestInNextSession() {
        var request = QuickAssistFocusRequest()
        XCTAssertFalse(request.consume(0, isActive: true))
        XCTAssertTrue(request.consume(1, isActive: true))
        XCTAssertFalse(request.consume(0, isActive: false))
        XCTAssertFalse(request.consume(1, isActive: false))
        XCTAssertTrue(request.consume(1, isActive: true))
    }

    func testCancelledPartialAnswerRemainsReadableWithoutReplacingSavedTurn() {
        var state = QuickAssistRenderFixtures.state(isLoading: false, selectedResponse: "Saved answer", streamingDraft: nil)
        state.interruptedResponse = "Partial answer"
        XCTAssertEqual(state.responseForDisplay, "Partial answer")
        XCTAssertEqual(state.copyableResponse, "Partial answer")
        XCTAssertEqual(state.selectedResponse, "Saved answer")
        state.interruptedResponse = nil
        XCTAssertEqual(state.responseForDisplay, "Saved answer")
    }

    @MainActor
    func testCancelRetainsDraftAndSwitchingThreadClearsIt() {
        let controller = SessionController.shared
        controller.resetSessionStateForTesting()
        defer { controller.resetSessionStateForTesting() }
        controller.activeQuickAssistThreadID = "cancelled-thread"
        controller.quickAssistLastStableResponse = "Saved answer"
        controller.quickAssistStreamingDraft = "Partial generated answer"
        controller.quickAssistQuestion = "Keep this draft"
        controller.quickAssistRequestQuestion = "Original submitted question"
        controller.isQuickAssistLoading = true
        controller.cancelActiveRequest()
        XCTAssertEqual(controller.quickAssistInterruptedAnswer?.response, "Partial generated answer")
        XCTAssertEqual(controller.quickAssistInterruptedAnswer?.question, "Original submitted question")
        XCTAssertEqual(controller.quickAssistInterruptedAnswer?.reason, .cancelled)
        XCTAssertEqual(controller.quickAssistLastStableResponse, "Saved answer")
        XCTAssertEqual(controller.quickAssistQuestion, "Keep this draft")
        XCTAssertFalse(controller.isQuickAssistLoading)
        XCTAssertNil(controller.quickAssistStreamingDraft)
        controller.activeQuickAssistThreadID = "another-thread"
        XCTAssertNil(controller.quickAssistInterruptedAnswer)
        XCTAssertNil(controller.quickAssistRequestQuestion)
    }

    func testStreamingDraftWinsOverStableResponseWhileLoading() {
        let state = QuickAssistRenderFixtures.state(isLoading: true, selectedResponse: "stable response", streamingDraft: "live draft")

        XCTAssertTrue(state.hasStreamingDraft)
        XCTAssertTrue(state.shouldRenderStreamingDraft)
        XCTAssertEqual(state.responseForDisplay, "stable response")
        XCTAssertFalse(state.isUpdatingPreviousResult)
    }

    func testStreamingDraftDoesNotRenderWhenNotLoading() {
        let state = QuickAssistRenderFixtures.state(isLoading: false, selectedResponse: "stable response", streamingDraft: "live draft")

        XCTAssertTrue(state.hasStreamingDraft)
        XCTAssertFalse(state.shouldRenderStreamingDraft)
    }

    func testUpdatingPreviousResultWhenLoadingWithoutDraft() {
        let state = QuickAssistRenderFixtures.state(isLoading: true, selectedResponse: "stable response", streamingDraft: nil)

        XCTAssertTrue(state.isUpdatingPreviousResult)
        XCTAssertTrue(state.showsStage)
    }

    func testEmptyStateShowsNoStage() {
        let state = QuickAssistRenderFixtures.state(isLoading: false, selectedResponse: nil, streamingDraft: nil)

        XCTAssertFalse(state.showsStage)
        XCTAssertFalse(state.hasTurns)
    }

    func testHeaderModelHidesNavigatorForEmptyThread() {
        let model = QuickAssistThreadHeaderModel(state: QuickAssistRenderFixtures.state(isLoading: false, selectedResponse: nil, streamingDraft: nil))

        XCTAssertFalse(model.shouldShowTurnNavigator)
        XCTAssertEqual(model.modeItems, QuickAssistThreadMode.allCases)
        XCTAssertEqual(model.selectedMode, .auto)
        XCTAssertNil(model.resolvedModeCaption)
    }

    func testHeaderModelShowsNavigatorAndFamilyForActiveThread() {
        let state = QuickAssistRenderFixtures.state(
            isLoading: false,
            selectedResponse: "stable response",
            streamingDraft: nil,
            answerFamilyBadge: QuickAssistAnswerFamilyBadge(familyName: "Conflict", frameworkName: "STAR-L", isProbe: false),
            resolvedMode: .behavioural,
            modeDiverges: true
        )
        let model = QuickAssistThreadHeaderModel(state: state)

        XCTAssertTrue(model.shouldShowTurnNavigator)
        XCTAssertEqual(model.familyBadgeText, "Conflict · STAR-L")
        XCTAssertEqual(model.familyTone, .success)
        XCTAssertEqual(model.resolvedModeCaption, "resolved as Behavioural")
        XCTAssertTrue(model.shouldShowOpenAISourceMenu)
    }

    func testActiveToolTracePrefersLiveTraceWhenAvailable() {
        let liveTrace = QuickAssistToolTrace(turnID: nil, steps: [QuickAssistRenderFixtures.runningToolStep])
        let selectedTrace = QuickAssistToolTrace(turnID: UUID(), steps: [])
        let state = QuickAssistRenderFixtures.state(
            isLoading: true,
            selectedResponse: "stable response",
            streamingDraft: "live draft",
            selectedToolTrace: selectedTrace,
            liveToolTrace: liveTrace
        )

        XCTAssertEqual(state.activeToolTrace, liveTrace)
    }

    func testSavedTurnUsesItsOwnTraceAfterGeneration() {
        let liveTrace = QuickAssistToolTrace(turnID: nil, steps: [QuickAssistRenderFixtures.runningToolStep])
        let selectedTrace = QuickAssistToolTrace(turnID: UUID(), steps: [])
        let state = QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: "Saved answer", streamingDraft: nil,
            selectedToolTrace: selectedTrace, liveToolTrace: liveTrace
        )
        XCTAssertEqual(state.activeToolTrace, selectedTrace)
    }
}
