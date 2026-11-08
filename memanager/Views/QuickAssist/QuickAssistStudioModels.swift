import SwiftUI

/// Everything the studio needs to render one frame. Built by the shell
/// from the live services so the studio itself never touches a singleton.
struct QuickAssistStudioState {
    let isLoading: Bool
    let selectedResponse: String?
    let selectedTurnID: UUID?
    let selectedTurnProvider: AIProviderType?
    let selectedResponseSourceLabel: String?
    let selectedOpenAIRawGuardedIdentical: Bool
    let lastStableResponse: String?
    let lastStableTurnID: UUID?
    let responseCount: Int
    let selectedIndex: Int?
    let streamingDraft: String?
    let selectedMode: Binding<QuickAssistThreadMode>
    let resolvedMode: QuickAssistThreadMode?
    let modeDiverges: Bool
    let question: Binding<String>
    let extraContext: Binding<String>
    let isExtraContextExpanded: Binding<Bool>
    let questionFocusNonce: Int
    let contextStatusMessage: String?
    let routeSummary: String?
    let relatedMemorySnippets: [RelatedMemorySnippet]
    let verificationRecord: QuickAssistVerificationRecord?
    let feedbackStatus: QuickAssistTurnFeedbackStatus
    let recoveryPlan: QuickAssistRecoveryPlan?
    let hubNudge: HubNudge?
    let liveResponseCard: ResponseCard?
    let liveResponseCardCount: Int
    let coachFindings: [CoachFindingRecord]
    let experimentThreadID: String?
    let experimentComparison: WorkstreamThreadComparison?
    let activeExperiment: QuickAssistExperiment?
    let activeTier: QuickAssistModelTier
    let activeThreadID: String?
    let contextHints: [QuickAssistComposerContextHint]
    let turnSummaries: [QuickAssistTurnSummary]
    let forceTools: Binding<Bool>
    let toolCallEvents: [ProjectToolCallEvent]
    let selectedToolTrace: QuickAssistToolTrace?
    let liveToolTrace: QuickAssistToolTrace?
    let selectedReasoningFlow: QuickAssistReasoningFlow?
    let liveReasoningFlow: QuickAssistReasoningFlow?
    let toolAvailability: QuickAssistToolAvailability
    let answerFamilyBadge: QuickAssistAnswerFamilyBadge?
    var displayedQuestion: String? = nil
    var interruptedResponse: String? = nil
    var interruptionMessage: String? = nil
    var historySearchFocusNonce: Int = 0
    var sourceRecord: QuickAssistCallRecord? = nil
}

/// Retained views consume explicit focus requests only while active.
struct QuickAssistFocusRequest {
    private var handledNonce = 0

    mutating func consume(_ nonce: Int, isActive: Bool) -> Bool {
        if nonce == 0 {
            handledNonce = 0
            return false
        }
        guard isActive, nonce > 0, nonce != handledNonce else { return false }
        handledNonce = nonce
        return true
    }
}

/// Every action the studio can trigger, as closures the shell wires to the
/// session controller.
struct QuickAssistStudioActions {
    let onGenerate: () -> Void
    let onFollowUp: () -> Void
    let onAskSideQuestion: () -> Void
    let onFocusQuestion: () -> Void
    let onNewThread: () -> Void
    let onPreviousResponse: () -> Void
    let onNextResponse: () -> Void
    let onAutoSideQuestion: () -> Void
    let onAcceptTurn: () -> Void
    let onRejectTurn: () -> Void
    let onDismissHubNudge: () -> Void
    let onCycleLiveResponseCard: () -> Void
    let onPinLiveResponseCard: () -> Void
    let onRefineLiveResponseCard: () -> Void
    let onDismissLiveResponseCard: () -> Void
    let onApplyCoachSuggestion: (String) -> Void
    let onDismissCoachFinding: (String) -> Void
    let onOpenTimeline: (String) -> Void
    let onToggleMemoryPin: (String) -> Void
    let onSetThreadMode: (QuickAssistThreadMode) -> Void
    let onApplyRecoveryAction: (QuickAssistRecoveryAction) -> Void
    let onCreateExperiment: () -> Void
    let onCompareExperiment: () -> Void
    let onAdoptExperiment: (String) -> Void
    let onClearExperiment: () -> Void
    let onSelectTurn: (Int) -> Void
    var onCancel: () -> Void = {}
}

/// One turn in the active thread, as the navigator sees it.
struct QuickAssistTurnSummary: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let verificationStatus: QuickAssistVerificationStatus?
}
