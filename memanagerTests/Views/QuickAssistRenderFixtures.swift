import Foundation
import SwiftUI
@testable import memanager

/// Realistic Quick Assist data for unit and render tests: a STAR answer in
/// the playbook contract shape, turns, threads, and a state builder with
/// constant bindings.
enum QuickAssistRenderFixtures {
    static let starAnswer = """
    **Say first:** The short version is that I brought two teams back onto one roadmap by making the tradeoff explicit.

    ### Situation
    * Two platform teams were shipping conflicting APIs for the same customer flow
    * The release was slipping by three weeks and nobody owned the call

    ### Task
    * I owned the integration and the release date, so I had to get one API chosen fast

    ### Action
    * Wrote a one page decision memo with both options costed in engineer weeks
    * Ran a thirty minute review with both leads and picked the shared API on the spot
    * Cut scope on the second migration so the date held

    ### Result
    * Shipped on the original date
    * Support tickets on that API dropped forty percent the next quarter

    ### Lesson
    * Make the tradeoff visible early instead of negotiating in private
    """

    static let streamingDraft = """
    **Say first:** I would start by narrowing the problem to the one metric the team actually moved.

    ### Situation
    * Checkout conversion had dropped two points after a redesign

    ### Task
    * I was asked to find the cause within a wee
    """

    static var runningToolStep: QuickAssistToolTraceStep {
        QuickAssistToolTraceStep(
            id: "live",
            toolName: "search_files",
            state: .running,
            iteration: 0,
            displayInput: "pattern: SessionController",
            rawArgumentsJSON: #"{"pattern":"SessionController"}"#,
            resultContent: nil,
            contentTruncated: false,
            overflowPath: nil,
            startedAt: Date(),
            durationMs: nil,
            evidenceKind: .generic(preview: ""),
            referencedFiles: []
        )
    }

    static func turnSummaries(count: Int) -> [QuickAssistTurnSummary] {
        let statuses: [QuickAssistVerificationStatus] = [.verified, .needsReview, .verified, .pending, .failed]
        return (0..<count).map { index in
            QuickAssistTurnSummary(id: UUID(), index: index, verificationStatus: statuses[index % statuses.count])
        }
    }

    static func threadSummaries(now: Date = Date()) -> [QuickAssistThreadSummary] {
        let titles = [
            "Tell me about a time you disagreed with a lead",
            "Walk me through the sliding window approach",
            "Design a rate limiter for a public API",
            "Why are you leaving your current role",
            "Debug the flaky checkout test"
        ]
        let ages: [TimeInterval] = [120, 3_600, 90_000, 100_000, 5 * 86_400]
        return titles.enumerated().map { index, title in
            QuickAssistThreadSummary(
                id: "thread-\(index)",
                title: title,
                createdAt: now.addingTimeInterval(-ages[index] - 600),
                updatedAt: now.addingTimeInterval(-ages[index]),
                originSessionId: "session-1",
                parentThreadId: index == 2 ? "thread-1" : nil,
                turnCount: index + 1,
                lastTurnAt: now.addingTimeInterval(-ages[index]),
                previewText: "Say first: the short version is that I kept the release on the calendar by making the tradeoff explicit."
            )
        }
    }

    static var threadMetadata: [String: ThreadCardMetadata] {
        [
            "thread-0": ThreadCardMetadata(id: "thread-0", verifiedCount: 1, needsReviewCount: 0, failedCount: 0, pendingCount: 0, dominantModelTier: .fast, coachFindingCount: 0),
            "thread-1": ThreadCardMetadata(id: "thread-1", verifiedCount: 1, needsReviewCount: 1, failedCount: 0, pendingCount: 0, dominantModelTier: .deep, coachFindingCount: 2),
            "thread-2": ThreadCardMetadata(id: "thread-2", verifiedCount: 3, needsReviewCount: 0, failedCount: 0, pendingCount: 0, dominantModelTier: .fast, coachFindingCount: 0),
            "thread-3": ThreadCardMetadata(id: "thread-3", verifiedCount: 0, needsReviewCount: 0, failedCount: 1, pendingCount: 3, dominantModelTier: .fast, coachFindingCount: 1)
        ]
    }

    static let verifiedRecord = QuickAssistVerificationRecord(status: .verified, confidence: 0.91, unsupportedClaimCount: 0, missingQuestions: [], suggestedFollowUp: nil)
    static let reviewRecord = QuickAssistVerificationRecord(status: .needsReview, confidence: 0.58, unsupportedClaimCount: 2, missingQuestions: [], suggestedFollowUp: nil)

    static func state(
        isLoading: Bool,
        selectedResponse: String?,
        streamingDraft: String?,
        turnCount: Int? = nil,
        selectedIndex: Int? = nil,
        provider: AIProviderType = .openai,
        verificationRecord: QuickAssistVerificationRecord? = nil,
        feedbackStatus: QuickAssistTurnFeedbackStatus = .none,
        routeSummary: String? = nil,
        contextStatusMessage: String? = nil,
        answerFamilyBadge: QuickAssistAnswerFamilyBadge? = nil,
        resolvedMode: QuickAssistThreadMode? = nil,
        modeDiverges: Bool = false,
        activeTier: QuickAssistModelTier = .fast,
        activeThreadID: String? = nil,
        contextHints: [QuickAssistComposerContextHint] = [],
        selectedToolTrace: QuickAssistToolTrace? = nil,
        liveToolTrace: QuickAssistToolTrace? = nil,
        displayedQuestion: String? = "Tell me about a time you resolved a conflict between teams."
    ) -> QuickAssistStudioState {
        let count = turnCount ?? (selectedResponse == nil ? 0 : 1)
        return QuickAssistStudioState(
            isLoading: isLoading,
            selectedResponse: selectedResponse,
            selectedTurnID: selectedResponse == nil ? nil : UUID(),
            selectedTurnProvider: provider,
            selectedResponseSourceLabel: provider == .openai ? "Guarded" : nil,
            selectedOpenAIRawGuardedIdentical: false,
            lastStableResponse: nil,
            lastStableTurnID: nil,
            responseCount: count,
            selectedIndex: selectedIndex ?? (count == 0 ? nil : count - 1),
            streamingDraft: streamingDraft,
            selectedMode: .constant(.auto),
            resolvedMode: resolvedMode,
            modeDiverges: modeDiverges,
            question: .constant(""),
            extraContext: .constant(""),
            isExtraContextExpanded: .constant(false),
            questionFocusNonce: 0,
            contextStatusMessage: contextStatusMessage,
            routeSummary: routeSummary,
            relatedMemorySnippets: [],
            verificationRecord: verificationRecord,
            feedbackStatus: feedbackStatus,
            recoveryPlan: nil,
            hubNudge: nil,
            liveResponseCard: nil,
            liveResponseCardCount: 0,
            coachFindings: [],
            experimentThreadID: nil,
            experimentComparison: nil,
            activeExperiment: nil,
            activeTier: activeTier,
            activeThreadID: activeThreadID,
            contextHints: contextHints,
            turnSummaries: turnSummaries(count: count),
            forceTools: .constant(false),
            toolCallEvents: [],
            selectedToolTrace: selectedToolTrace,
            liveToolTrace: liveToolTrace,
            selectedReasoningFlow: nil,
            liveReasoningFlow: nil,
            toolAvailability: .noProjectFolder,
            answerFamilyBadge: answerFamilyBadge,
            displayedQuestion: selectedResponse == nil ? nil : displayedQuestion
        )
    }

    static let actions = QuickAssistStudioActions(
        onGenerate: {}, onFollowUp: {}, onAskSideQuestion: {}, onFocusQuestion: {}, onNewThread: {},
        onPreviousResponse: {}, onNextResponse: {}, onAutoSideQuestion: {}, onAcceptTurn: {}, onRejectTurn: {},
        onDismissHubNudge: {}, onCycleLiveResponseCard: {}, onPinLiveResponseCard: {}, onRefineLiveResponseCard: {},
        onDismissLiveResponseCard: {}, onApplyCoachSuggestion: { _ in }, onDismissCoachFinding: { _ in },
        onOpenTimeline: { _ in }, onToggleMemoryPin: { _ in }, onSetThreadMode: { _ in },
        onApplyRecoveryAction: { _ in }, onCreateExperiment: {}, onCompareExperiment: {},
        onAdoptExperiment: { _ in }, onClearExperiment: {}, onSelectTurn: { _ in }
    )

    static let panelActions = QuickAssistThreadsPanelActions(
        onRefresh: {}, onDeleteAll: {}, onOpenSelected: {}, onInspectSelected: {}, onNewThread: {},
        onSelect: { _ in }, onDelete: { _ in }, onInspect: { _ in }, onConfirmDelete: {}, onCancelDelete: {}
    )
}
