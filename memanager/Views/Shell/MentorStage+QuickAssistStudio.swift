import SwiftUI

/// Builds the Quick Assist studio's state and action bundles from the live
/// services. Kept apart from the stage so MentorStage only forwards them.
extension MentorStage {
    var quickAssistStudioState: QuickAssistStudioState {
        var state = QuickAssistStudioState(
            isLoading: controller.isQuickAssistLoading,
            selectedResponse: controller.selectedQuickAssistResponseText,
            selectedTurnID: controller.selectedQuickAssistTurn?.id,
            selectedTurnProvider: controller.selectedQuickAssistTurn?.provider,
            selectedResponseSourceLabel: controller.selectedQuickAssistResponseSourceLabel,
            selectedOpenAIRawGuardedIdentical: controller.selectedQuickAssistOpenAIRawGuardedIdentical,
            lastStableResponse: controller.quickAssistLastStableResponse,
            lastStableTurnID: controller.quickAssistLastStableTurnID,
            responseCount: controller.quickAssistTurns.count,
            selectedIndex: controller.selectedQuickAssistTurnIndex,
            streamingDraft: controller.quickAssistStreamingDraft,
            selectedMode: $controller.quickAssistSelectedMode,
            resolvedMode: controller.quickAssistResolvedMode,
            modeDiverges: controller.quickAssistResolvedMode != nil && controller.quickAssistResolvedMode != controller.quickAssistSelectedMode,
            question: $controller.quickAssistQuestion,
            extraContext: $controller.quickAssistExtraContext,
            isExtraContextExpanded: $controller.quickAssistExtraContextExpanded,
            questionFocusNonce: controller.quickAssistQuestionFocusNonce,
            contextStatusMessage: controller.quickAssistContextStatusMessage,
            routeSummary: controller.quickAssistRouteSummary,
            relatedMemorySnippets: controller.quickAssistRelatedMemorySnippets,
            verificationRecord: controller.quickAssistInterruptedAnswer == nil ? controller.quickAssistVerificationRecord : nil,
            feedbackStatus: controller.quickAssistSelectedTurnFeedbackStatus,
            recoveryPlan: controller.quickAssistRecoveryPlan,
            hubNudge: controller.activeHubNudge,
            liveResponseCard: controller.activeLiveResponseCard,
            liveResponseCardCount: controller.liveResponseCards.count,
            coachFindings: controller.activeCoachFindings,
            experimentThreadID: controller.quickAssistExperimentThreadID,
            experimentComparison: controller.quickAssistExperimentComparison,
            activeExperiment: controller.activeQuickAssistExperiment,
            activeTier: controller.quickAssistActiveTier,
            activeThreadID: controller.activeQuickAssistThreadID,
            contextHints: quickAssistContextHints,
            turnSummaries: buildTurnSummaries(),
            forceTools: $controller.quickAssistForceTools,
            toolCallEvents: controller.quickAssistToolCallEvents,
            selectedToolTrace: controller.quickAssistSelectedToolTrace,
            liveToolTrace: controller.quickAssistLiveToolTrace,
            selectedReasoningFlow: controller.quickAssistSelectedReasoningFlow,
            liveReasoningFlow: controller.quickAssistLiveReasoningFlow,
            toolAvailability: controller.quickAssistToolAvailability,
            answerFamilyBadge: controller.quickAssistAnswerFamilyBadge,
            displayedQuestion: controller.quickAssistInterruptedAnswer?.question
                ?? (controller.isQuickAssistLoading && !(controller.quickAssistStreamingDraft ?? "").isEmpty
                    ? controller.quickAssistRequestQuestion : controller.selectedQuickAssistTurn?.question),
            interruptedResponse: controller.quickAssistInterruptedAnswer?.response,
            interruptionMessage: controller.quickAssistInterruptedAnswer.map {
                $0.reason == .cancelled ? "Generation cancelled" : "Generation interrupted"
            },
            historySearchFocusNonce: controller.quickAssistHistorySearchFocusNonce
        )
        state.sourceRecord = state.sourceTurnID.flatMap { controller.quickAssistCallByTurnID(turnID: $0) }
        return state
    }

    var quickAssistStudioActions: QuickAssistStudioActions {
        QuickAssistStudioActions(
            onGenerate: { controller.quickAssist() },
            onFollowUp: { controller.triggerQuickAssistFollowUp() },
            onAskSideQuestion: { controller.askQuickAssistSideQuestion() },
            onFocusQuestion: { controller.focusQuickAssistQuestionInput() },
            onNewThread: { controller.createNewQuickAssistThread() },
            onPreviousResponse: { controller.selectPreviousQuickAssistTurn() },
            onNextResponse: { controller.selectNextQuickAssistTurn() },
            onAutoSideQuestion: { controller.triggerQuickAssistAutoSideQuestionFromSelectedResponse() },
            onAcceptTurn: { applyFeedback(accepted: true) },
            onRejectTurn: { applyFeedback(accepted: false) },
            onDismissHubNudge: { controller.dismissHubNudge() },
            onCycleLiveResponseCard: { controller.cycleLiveResponseCard() },
            onPinLiveResponseCard: { controller.pinActiveResponseCardToTeleprompter() },
            onRefineLiveResponseCard: { controller.refineActiveResponseCard() },
            onDismissLiveResponseCard: { controller.dismissLiveResponseCard() },
            onApplyCoachSuggestion: { controller.applyCoachSuggestion($0) },
            onDismissCoachFinding: { controller.dismissCoachFinding($0) },
            onOpenTimeline: { controller.inspectThreadInTimeline(threadID: $0) },
            onToggleMemoryPin: { controller.toggleQuickAssistMemoryPin($0) },
            onSetThreadMode: { controller.setQuickAssistThreadMode($0) },
            onApplyRecoveryAction: { controller.applyQuickAssistRecoveryAction($0) },
            onCreateExperiment: { controller.createQuickAssistExperimentFromSelectedTurn() },
            onCompareExperiment: { controller.compareQuickAssistExperiment() },
            onAdoptExperiment: { controller.adoptQuickAssistBranch(threadID: $0) },
            onClearExperiment: { controller.clearQuickAssistExperiment() },
            onSelectTurn: { controller.selectQuickAssistTurn(index: $0) },
            onCancel: { controller.cancelActiveRequest() }
        )
    }

    private func applyFeedback(accepted: Bool) {
        guard let turnID = controller.selectedQuickAssistTurn?.id.uuidString else { return }
        controller.applyQuickAssistTurnFeedback(
            QuickAssistTurnFeedback(turnID: turnID, accepted: accepted, note: nil)
        )
    }

    private var quickAssistContextHints: [QuickAssistComposerContextHint] {
        let hasTranscript =
            !audioService.transcriptEntries.isEmpty ||
            !audioService.partialMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !audioService.partialOther.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return QuickAssistContextHintBuilder.hints(
            hasTranscript: hasTranscript,
            screenshotCount: screenshotService.screenshots.count,
            pinnedMemoryCount: controller.quickAssistRelatedMemorySnippets.filter(\.isPinned).count,
            hasPriorTurn: !controller.quickAssistTurns.isEmpty
        )
    }

    private func buildTurnSummaries() -> [QuickAssistTurnSummary] {
        controller.quickAssistTurns.enumerated().map { index, turn in
            let callRecord = controller.quickAssistCallByTurnID(turnID: turn.id)
            return QuickAssistTurnSummary(id: turn.id, index: index, verificationStatus: callRecord?.verificationStatus)
        }
    }
}
