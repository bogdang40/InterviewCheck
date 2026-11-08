import XCTest
@testable import memanager

@MainActor
final class SessionControllerQuickAssistStreamingTests: XCTestCase {
    private var controller: SessionController {
        SessionController.shared
    }

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testQuickAssistStreamUpdatesAreMonotonicAndFinalTextIsComplete() {
        let sessionID = UUID()
        let requestID = UUID()
        controller.session.id = sessionID
        controller.setActiveQuickAssistRequestIDForTesting(requestID)
        controller.isQuickAssistLoading = true

        let chunks = ["So ", "I'm ", "starting with requirements."]
        var accumulated = ""

        for chunk in chunks {
            accumulated += chunk
            let didApply = controller.applyQuickAssistStreamUpdateForTesting(
                accumulated,
                sessionID: sessionID,
                requestID: requestID
            )
            XCTAssertTrue(didApply)
            XCTAssertEqual(controller.quickAssistStreamingDraft, accumulated)
            // Only the draft publishes per chunk; quickAssistResponse is
            // written once at settle so streaming costs one objectWillChange
            // per chunk instead of two.
            XCTAssertNil(controller.quickAssistResponse)
        }

        XCTAssertEqual(controller.quickAssistStreamingDraft, chunks.joined())
        XCTAssertNil(controller.quickAssistResponse)
    }

    func testQuickAssistStreamUpdateRejectsSettledRequest() {
        let requestID = UUID()
        controller.setActiveQuickAssistRequestIDForTesting(requestID)
        controller.isQuickAssistLoading = false
        controller.quickAssistResponse = "Completed answer"
        XCTAssertFalse(controller.applyQuickAssistStreamUpdateForTesting(
            "Late chunk", sessionID: controller.session.id, requestID: requestID
        ))
        XCTAssertNil(controller.quickAssistStreamingDraft)
        XCTAssertEqual(controller.quickAssistResponse, "Completed answer")
    }

    func testQuickAssistStreamUpdateRejectsCancelledRequest() {
        let requestID = UUID()
        controller.setActiveQuickAssistRequestIDForTesting(requestID)
        controller.isQuickAssistLoading = true
        controller.quickAssistStreamingDraft = "Retained partial"
        controller.cancelActiveRequest()
        XCTAssertFalse(controller.applyQuickAssistStreamUpdateForTesting(
            "Late chunk", sessionID: controller.session.id, requestID: requestID
        ))
        XCTAssertNil(controller.quickAssistStreamingDraft)
        XCTAssertEqual(controller.quickAssistResponse, "Retained partial")
    }

    func testQuickAssistStreamUpdateRejectsStaleRequestID() {
        let sessionID = UUID()
        controller.session.id = sessionID
        controller.setActiveQuickAssistRequestIDForTesting(UUID())
        controller.isQuickAssistLoading = true
        controller.quickAssistResponse = "latest"

        let didApply = controller.applyQuickAssistStreamUpdateForTesting(
            "stale",
            sessionID: sessionID,
            requestID: UUID()
        )

        XCTAssertFalse(didApply)
        XCTAssertEqual(controller.quickAssistResponse, "latest")
    }

    func testSelectingQuickAssistTurnsUpdatesDisplayedResponse() {
        controller.quickAssistTurns = [
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(),
                transcriptDelta: "Me: first",
                question: "q1",
                response: "answer 1",
                contextMode: .conversation,
                modelTier: .fast
            ),
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(),
                transcriptDelta: "Me: second",
                question: "q2",
                response: "answer 2",
                contextMode: .conversation,
                modelTier: .deep
            )
        ]

        controller.selectQuickAssistTurn(index: 0)
        XCTAssertEqual(controller.selectedQuickAssistTurnIndex, 0)
        XCTAssertEqual(controller.quickAssistResponse, "answer 1")

        controller.selectNextQuickAssistTurn()
        XCTAssertEqual(controller.selectedQuickAssistTurnIndex, 1)
        XCTAssertEqual(controller.quickAssistResponse, "answer 2")

        controller.selectPreviousQuickAssistTurn()
        XCTAssertEqual(controller.selectedQuickAssistTurnIndex, 0)
        XCTAssertEqual(controller.quickAssistResponse, "answer 1")
    }

    func testOpenAIQuickAssistDisplayModeSwitchesBetweenRawAndGuarded() {
        let settings = SettingsManager.shared
        let originalMode = settings.openAIQuickAssistDisplayMode
        let originalGuard = settings.openAIVoiceGuardEnabled
        defer {
            settings.openAIQuickAssistDisplayMode = originalMode
            settings.openAIVoiceGuardEnabled = originalGuard
        }
        settings.openAIVoiceGuardEnabled = true

        controller.quickAssistTurns = [
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(),
                transcriptDelta: "Me: first",
                question: "q1",
                response: "applied answer",
                provider: .openai,
                rawResponse: "raw answer",
                guardedResponse: "guarded answer",
                contextMode: .conversation,
                modelTier: .fast
            )
        ]

        settings.openAIQuickAssistDisplayMode = .response
        controller.selectQuickAssistTurn(index: 0)
        XCTAssertEqual(controller.quickAssistResponse, "raw answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseText, "raw answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseSourceLabel, "Raw")

        settings.openAIQuickAssistDisplayMode = .guarded
        controller.selectQuickAssistTurn(index: 0)
        XCTAssertEqual(controller.quickAssistResponse, "guarded answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseText, "guarded answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseSourceLabel, "Guarded")
    }

    func testOpenAIGuardDisabledForcesRawDisplayRegardlessOfMode() {
        let settings = SettingsManager.shared
        let originalMode = settings.openAIQuickAssistDisplayMode
        let originalGuard = settings.openAIVoiceGuardEnabled
        defer {
            settings.openAIQuickAssistDisplayMode = originalMode
            settings.openAIVoiceGuardEnabled = originalGuard
        }

        controller.quickAssistTurns = [
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(),
                transcriptDelta: "Me: first",
                question: "q1",
                response: "applied answer",
                provider: .openai,
                rawResponse: "raw answer",
                guardedResponse: "guarded answer",
                contextMode: .conversation,
                modelTier: .fast
            )
        ]

        settings.openAIVoiceGuardEnabled = false
        settings.openAIQuickAssistDisplayMode = .guarded
        controller.selectQuickAssistTurn(index: 0)

        XCTAssertEqual(controller.quickAssistResponse, "raw answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseText, "raw answer")
        XCTAssertEqual(controller.selectedQuickAssistResponseSourceLabel, "Raw")
    }

    func testNonOpenAIQuickAssistTurnIgnoresOpenAIDisplayMode() {
        let settings = SettingsManager.shared
        let originalMode = settings.openAIQuickAssistDisplayMode
        let originalGuard = settings.openAIVoiceGuardEnabled
        defer {
            settings.openAIQuickAssistDisplayMode = originalMode
            settings.openAIVoiceGuardEnabled = originalGuard
        }
        settings.openAIVoiceGuardEnabled = true

        controller.quickAssistTurns = [
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(),
                transcriptDelta: "Me: first",
                question: "q1",
                response: "provider response",
                provider: .claude,
                rawResponse: "raw answer",
                guardedResponse: "guarded answer",
                contextMode: .conversation,
                modelTier: .fast
            )
        ]

        settings.openAIQuickAssistDisplayMode = .response
        controller.selectQuickAssistTurn(index: 0)
        XCTAssertEqual(controller.quickAssistResponse, "provider response")
        XCTAssertEqual(controller.selectedQuickAssistResponseText, "provider response")
        XCTAssertEqual(controller.selectedQuickAssistResponseSourceLabel, "Response")
    }

    func testQuickAssistHistoryHotkeyGateTracksQuickAssistVisibility() {
        controller.isQuickAssistViewVisible = false
        XCTAssertFalse(controller.shouldConsumeQuickAssistHistoryHotkeys())

        controller.isQuickAssistViewVisible = true
        XCTAssertTrue(controller.shouldConsumeQuickAssistHistoryHotkeys())
    }

    func testQuickAssistModeHotkeyGateTracksQuickAssistVisibility() {
        controller.isQuickAssistViewVisible = false
        XCTAssertFalse(controller.shouldConsumeQuickAssistModeHotkeys())

        controller.isQuickAssistViewVisible = true
        XCTAssertTrue(controller.shouldConsumeQuickAssistModeHotkeys())
    }

    func testSelectingQuickAssistTurnTracksLastStableResponse() {
        let firstTurn = QuickAssistThread.Turn(
            id: UUID(),
            timestamp: Date(),
            transcriptDelta: "Me: first",
            question: "q1",
            response: "answer 1",
            contextMode: .conversation,
            modelTier: .fast
        )
        let secondTurn = QuickAssistThread.Turn(
            id: UUID(),
            timestamp: Date(),
            transcriptDelta: "Me: second",
            question: "q2",
            response: "answer 2",
            contextMode: .conversation,
            modelTier: .deep
        )
        controller.quickAssistTurns = [firstTurn, secondTurn]

        controller.selectQuickAssistTurn(index: 1)

        XCTAssertEqual(controller.quickAssistResponse, "answer 2")
        XCTAssertEqual(controller.quickAssistLastStableResponse, "answer 2")
        XCTAssertEqual(controller.quickAssistLastStableTurnID, secondTurn.id)
    }

    func testQuickAssistFocusMethodsIncrementHotkeyNonces() {
        controller.isQuickAssistViewVisible = false
        let questionNonce = controller.quickAssistQuestionFocusNonce
        let historyNonce = controller.quickAssistHistorySearchFocusNonce

        controller.focusQuickAssistQuestionInput()
        XCTAssertTrue(controller.isQuickAssistViewVisible)
        XCTAssertEqual(controller.quickAssistQuestionFocusNonce, questionNonce + 1)

        controller.focusQuickAssistHistorySearch()
        XCTAssertEqual(controller.quickAssistHistorySearchFocusNonce, historyNonce + 1)
    }

    func testCycleQuickAssistThreadModeFollowsSelectorOrderAndWraps() {
        let threadID = "thread-cycle"
        controller.activeQuickAssistThreadID = threadID
        controller.quickAssistSelectedMode = .auto
        controller.quickAssistThreadSummaries = [
            QuickAssistThreadSummary(
                id: threadID,
                title: "Mode Cycle",
                createdAt: Date(),
                updatedAt: Date(),
                selectedMode: .auto,
                originSessionId: nil,
                parentThreadId: nil,
                branchedFromTurnId: nil,
                turnCount: 0,
                lastTurnAt: nil,
                previewText: nil
            )
        ]

        let expectedOrder = Array(QuickAssistThreadMode.allCases.dropFirst()) + [.auto]
        for expectedMode in expectedOrder {
            controller.cycleQuickAssistThreadMode()
            XCTAssertEqual(controller.quickAssistSelectedMode, expectedMode)
        }
    }

    func testSetQuickAssistThreadModeDoesNotRewriteResolvedModeForCurrentTurn() {
        let threadID = "thread-mode-persistence"
        controller.activeQuickAssistThreadID = threadID
        controller.quickAssistResolvedMode = .conversation
        controller.quickAssistThreadSummaries = [
            QuickAssistThreadSummary(
                id: threadID,
                title: "Existing Turn",
                createdAt: Date(),
                updatedAt: Date(),
                selectedMode: .auto,
                originSessionId: nil,
                parentThreadId: nil,
                branchedFromTurnId: nil,
                turnCount: 1,
                lastTurnAt: Date(),
                previewText: "existing"
            )
        ]

        controller.setQuickAssistThreadMode(.debug)

        XCTAssertEqual(controller.quickAssistSelectedMode, .debug)
        XCTAssertEqual(controller.quickAssistResolvedMode, .conversation)
    }

    func testBehaviouralResponseStyleUsesStarPlusByDefault() {
        let decision = controller.behaviouralResponseStyleForTesting(
            question: "Tell me about a time you resolved conflict in your team.",
            transcript: "",
            source: .manual
        )

        XCTAssertEqual(decision, .starPlus)
    }

    func testBehaviouralResponseStyleUsesConversationalExceptionForAutoSideQuestion() {
        let decision = controller.behaviouralResponseStyleForTesting(
            question: "ignored",
            transcript: "Me: ignored",
            source: .auto
        )

        XCTAssertEqual(decision, .conversational(.autoSideQuestion))
    }

    func testQuickAssistHistoryThreadSelectionRespectsFilteredSummaries() {
        controller.isQuickAssistViewVisible = true
        controller.quickAssistThreadSummaries = [
            QuickAssistThreadSummary(
                id: "thread-a",
                title: "Algorithms prep",
                createdAt: Date(),
                updatedAt: Date(),
                originSessionId: nil,
                turnCount: 2,
                lastTurnAt: Date(),
                previewText: "arrays"
            ),
            QuickAssistThreadSummary(
                id: "thread-b",
                title: "System design",
                createdAt: Date(),
                updatedAt: Date(),
                originSessionId: nil,
                turnCount: 5,
                lastTurnAt: Date(),
                previewText: "caching"
            ),
            QuickAssistThreadSummary(
                id: "thread-c",
                title: "Algorithms follow-up",
                createdAt: Date(),
                updatedAt: Date(),
                originSessionId: nil,
                turnCount: 1,
                lastTurnAt: Date(),
                previewText: "graphs"
            )
        ]

        controller.quickAssistHistorySearchQuery = "algo"
        controller.quickAssistSelectedHistoryThreadID = "thread-a"

        controller.selectNextQuickAssistHistoryThread()
        XCTAssertEqual(controller.quickAssistSelectedHistoryThreadID, "thread-c")

        controller.selectPreviousQuickAssistHistoryThread()
        XCTAssertEqual(controller.quickAssistSelectedHistoryThreadID, "thread-a")
    }
}
