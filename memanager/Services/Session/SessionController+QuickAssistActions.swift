import Foundation

extension SessionController {
    
    /// Generate a new Quick Assist response (triggered by Cmd+/)
    /// This is a fresh start for context selection, while preserving response history.
    @MainActor
    func triggerQuickAssist() {
        triggerQuickAssist(mode: .conversation)
    }
    /// Generate a new Quick Assist response with explicit context mode
    /// This is a fresh start for context selection, while preserving response history.
    @MainActor
    func triggerQuickAssist(mode: QuickAssistContextMode = .conversation, forceTier: QuickAssistModelTier? = nil) {
        let now = Date().timeIntervalSince1970
        guard now - lastQuickAssistTriggerTime >= quickAssistTriggerCooldown else {
            self.logger.logDebugEvent(
                category: "quick_assist",
                name: "debounce_swallow",
                details: "entry=triggerQuickAssist, delta=\(now - lastQuickAssistTriggerTime)"
            )
            return
        }
        lastQuickAssistTriggerTime = now

        revealQuickAssistSurface()
        // Fresh start for continuation context while keeping existing turn history visible.
        // Timestamp is preserved so only NEW transcript entries (since last Quick Assist) are sent.
        quickAssistCoordinator.clearContinuationContext()
        quickAssist(isFollowUp: false, mode: mode, forceTier: forceTier)
    }
    /// Generate a follow-up Quick Assist response (triggered by Cmd+')
    /// Includes the previous Quick Assist response in context for continuation
    @MainActor
    func triggerQuickAssistFollowUp() {
        triggerQuickAssistFollowUp(mode: .conversation)
    }
    /// Generate a follow-up Quick Assist response with explicit context mode
    /// Includes the previous Quick Assist response in context for continuation
    @MainActor
    func triggerQuickAssistFollowUp(mode: QuickAssistContextMode = .conversation) {
        let now = Date().timeIntervalSince1970
        guard now - lastQuickAssistTriggerTime >= quickAssistTriggerCooldown else {
            self.logger.logDebugEvent(
                category: "quick_assist",
                name: "debounce_swallow",
                details: "entry=triggerQuickAssistFollowUp, delta=\(now - lastQuickAssistTriggerTime)"
            )
            return
        }
        lastQuickAssistTriggerTime = now

        revealQuickAssistSurface()
        let lastTier = quickAssistCoordinator.thread.lastModelTier
        quickAssist(isFollowUp: true, mode: mode, forceTier: lastTier)
    }
    @MainActor
    func triggerQuickAssistAutoSideQuestionFromSelectedResponse() {
        let now = Date().timeIntervalSince1970
        guard now - lastQuickAssistTriggerTime >= quickAssistTriggerCooldown else {
            self.logger.logDebugEvent(
                category: "quick_assist",
                name: "debounce_swallow",
                details: "entry=triggerQuickAssistAutoSideQuestion, delta=\(now - lastQuickAssistTriggerTime)"
            )
            return
        }
        lastQuickAssistTriggerTime = now

        var targetTurn = selectedQuickAssistTurn
        var targetIndex = selectedQuickAssistTurnIndex

        if targetTurn == nil || targetIndex == nil {
            if quickAssistTurns.isEmpty {
                ensureActiveQuickAssistThreadLoaded(selectNewest: true)
            }

            if let latestIndex = quickAssistTurns.indices.last {
                targetIndex = latestIndex
                targetTurn = quickAssistTurns[latestIndex]
                selectedQuickAssistTurnIndex = latestIndex
                quickAssistResponse = displayedQuickAssistResponse(for: quickAssistTurns[latestIndex])
            }
        }

        guard let selectedTurn = targetTurn,
              let selectedIndex = targetIndex else { return }
        revealQuickAssistSurface()

        let autoSideQuestionPrompt = """
        Based on my latest transcript and current screen, infer the single most relevant side question to continue from the selected response and answer it directly.
        Start your response with exactly one line:
        Inferred side question: <question>
        Then continue with:
        Answer:
        """
        let historyOverride = buildConversationHistoryThroughTurn(index: selectedIndex)
        quickAssist(
            isFollowUp: true,
            mode: selectedTurn.contextMode,
            forceTier: selectedTurn.modelTier,
            questionOverride: autoSideQuestionPrompt,
            previousResponseOverride: selectedTurn.response,
            conversationHistoryOverride: historyOverride,
            questionSourceOverride: .auto
        )
    }
}
