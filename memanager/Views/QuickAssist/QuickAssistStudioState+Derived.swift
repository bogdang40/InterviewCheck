import Foundation

/// Read only conveniences derived from the raw studio state, so views ask
/// one question instead of re deriving the same rules.
extension QuickAssistStudioState {
    var hasStreamingDraft: Bool {
        guard let streamingDraft else { return false }
        return !streamingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldRenderStreamingDraft: Bool {
        isLoading && hasStreamingDraft
    }

    var responseForDisplay: String? {
        if let interruptedResponse,
           !interruptedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return interruptedResponse
        }
        if let selectedResponse,
           !selectedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedResponse
        }
        if let lastStableResponse,
           !lastStableResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastStableResponse
        }
        return nil
    }

    var responseRenderSeed: String? {
        if let selectedTurnID {
            return selectedTurnID.uuidString
        }
        if let lastStableTurnID {
            return lastStableTurnID.uuidString
        }
        return nil
    }

    var hasTurns: Bool {
        responseCount > 0
    }

    var copyableResponse: String {
        shouldRenderStreamingDraft ? (streamingDraft ?? "") : (responseForDisplay ?? "")
    }

    var hasActiveThread: Bool {
        guard let activeThreadID else { return false }
        return !activeThreadID.isEmpty
    }

    var isOpenAITurn: Bool {
        selectedTurnProvider == .openai
    }

    var frameworkName: String? {
        answerFamilyBadge?.frameworkName
    }

    var runningToolCount: Int {
        toolCallEvents.filter { $0.phase == .started }.count
    }

    /// The stage shows a response, a draft, or the loading skeleton; only
    /// a thread with nothing in flight shows the empty state.
    var showsStage: Bool {
        shouldRenderStreamingDraft || responseForDisplay != nil || isLoading
    }

    /// A new turn is being produced while an older answer stays readable.
    var isUpdatingPreviousResult: Bool {
        isLoading && responseForDisplay != nil && !hasStreamingDraft
    }

    var activeToolTrace: QuickAssistToolTrace? {
        if isLoading || interruptedResponse != nil, let liveToolTrace, !liveToolTrace.isEmpty {
            return liveToolTrace
        }
        return selectedToolTrace
    }

    /// Prefer the live flow while a turn is running so newly emitted thoughts
    /// appear immediately, then fall back to the persisted view once the turn
    /// is selected from history.
    var activeReasoningFlow: QuickAssistReasoningFlow? {
        if isLoading || interruptedResponse != nil, let liveReasoningFlow, !liveReasoningFlow.isEmpty {
            return liveReasoningFlow
        }
        return selectedReasoningFlow
    }
}
