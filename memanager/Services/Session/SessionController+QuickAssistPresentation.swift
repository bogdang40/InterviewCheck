import Foundation

extension SessionController {
    var hasQuickAssistScrollableContent: Bool {
        if isQuickAssistLoading || !quickAssistTurns.isEmpty { return true }
        return [
            quickAssistResponse, quickAssistLastStableResponse,
            quickAssistStreamingDraft, quickAssistInterruptedAnswer?.response
        ].contains { text in
            !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    var preferredHotkeyScrollTarget: ScrollTarget {
        if isTranscriptViewVisible {
            return .transcript
        }

        if isMLGuideViewVisible {
            return .mlGuide
        }

        if isQuickAssistViewVisible, hasQuickAssistScrollableContent {
            return .quickAssist
        }

        return activeScrollTarget
    }
    var selectedQuickAssistTurn: QuickAssistThread.Turn? {
        guard let index = selectedQuickAssistTurnIndex,
              index >= 0,
              index < quickAssistTurns.count else {
            return nil
        }
        return quickAssistTurns[index]
    }
    var selectedQuickAssistResponseText: String? {
        guard let selectedQuickAssistTurn else { return nil }
        return displayedQuickAssistResponse(for: selectedQuickAssistTurn)
    }
    var selectedQuickAssistResponseSourceLabel: String? {
        guard let turn = selectedQuickAssistTurn else { return nil }
        return quickAssistResponseSourceLabel(for: turn.provider)
    }
    var selectedQuickAssistOpenAIRawGuardedIdentical: Bool {
        guard let turn = selectedQuickAssistTurn, turn.provider == .openai else {
            return false
        }
        return turn.rawResponse == turn.guardedResponse
    }
    func refreshQuickAssistDisplayedResponse() {
        let displayText = selectedQuickAssistResponseText
        quickAssistResponse = displayText
        rememberQuickAssistStableResponse(
            displayText,
            turnID: selectedQuickAssistTurn?.id
        )
    }
    func displayedQuickAssistResponse(for turn: QuickAssistThread.Turn) -> String {
        guard turn.provider == .openai else {
            return turn.response
        }

        if !settings.shouldApplyVoiceGuard(for: .openai) {
            return turn.rawResponse
        }

        switch settings.openAIQuickAssistDisplayMode {
        case .response:
            return turn.rawResponse
        case .guarded:
            return turn.guardedResponse
        }
    }
    func displayedQuickAssistResponse(
        provider: AIProviderType,
        rawResponse: String,
        guardedResponse: String,
        appliedResponse: String
    ) -> String {
        guard provider == .openai else {
            return appliedResponse
        }

        if !settings.shouldApplyVoiceGuard(for: .openai) {
            return rawResponse
        }

        switch settings.openAIQuickAssistDisplayMode {
        case .response:
            return rawResponse
        case .guarded:
            return guardedResponse
        }
    }
    func quickAssistResponseSourceLabel(for provider: AIProviderType) -> String {
        guard provider == .openai else {
            return "Response"
        }

        if !settings.shouldApplyVoiceGuard(for: .openai) {
            return "Raw"
        }

        switch settings.openAIQuickAssistDisplayMode {
        case .response:
            return "Raw"
        case .guarded:
            return "Guarded"
        }
    }
    func rememberQuickAssistStableResponse(_ response: String?, turnID: UUID?) {
        guard let response,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        quickAssistLastStableResponse = response
        quickAssistLastStableTurnID = turnID
    }
}
