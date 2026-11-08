import Foundation

extension SessionController {
    @MainActor
    func askQuickAssistSideQuestion() {
        let trimmedQuestion = quickAssistQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return }

        if let selectedTurn = selectedQuickAssistTurn,
           let selectedIndex = selectedQuickAssistTurnIndex {
            let historyOverride = buildConversationHistoryThroughTurn(index: selectedIndex)
            quickAssist(
                isFollowUp: true,
                mode: selectedTurn.contextMode,
                forceTier: selectedTurn.modelTier,
                questionOverride: trimmedQuestion,
                previousResponseOverride: selectedTurn.response,
                conversationHistoryOverride: historyOverride,
                questionSourceOverride: .manual
            )
            return
        }

        if let lastTurn = quickAssistTurns.last {
            quickAssist(
                isFollowUp: true,
                mode: lastTurn.contextMode,
                forceTier: lastTurn.modelTier,
                questionOverride: trimmedQuestion,
                questionSourceOverride: .manual
            )
            return
        }

        quickAssist(
            isFollowUp: false,
            questionOverride: trimmedQuestion,
            questionSourceOverride: .manual
        )
    }
    func selectQuickAssistTurn(index: Int) {
        guard !isQuickAssistLoading else { return }
        guard index >= 0, index < quickAssistTurns.count else { return }
        quickAssistInterruptedAnswer = nil
        selectedQuickAssistTurnIndex = index
        if isQuickAssistViewVisible {
            activeScrollTarget = .quickAssist
        }
        let displayed = displayedQuickAssistResponse(for: quickAssistTurns[index])
        quickAssistResponse = displayed
        rememberQuickAssistStableResponse(
            displayed,
            turnID: quickAssistTurns[index].id
        )
        syncQuickAssistSelectedTurnMetadata()
        refreshQuickAssistRelatedMemoryContext(trigger: .turnSelection)
    }
    func selectNextQuickAssistTurn() {
        guard !isQuickAssistLoading else { return }
        guard !quickAssistTurns.isEmpty else { return }
        let current = selectedQuickAssistTurnIndex ?? (quickAssistTurns.count - 1)
        let next = min(current + 1, quickAssistTurns.count - 1)
        selectQuickAssistTurn(index: next)
    }
    func selectPreviousQuickAssistTurn() {
        guard !isQuickAssistLoading else { return }
        guard !quickAssistTurns.isEmpty else { return }
        let current = selectedQuickAssistTurnIndex ?? (quickAssistTurns.count - 1)
        let previous = max(current - 1, 0)
        selectQuickAssistTurn(index: previous)
    }
    /// Show the Quick Assist view without regenerating (for tab/Cmd+7 navigation)
    @MainActor
    func showQuickAssist(clearInputs: Bool = false) {
        revealQuickAssistSurface()
        quickAssistPendingDeletionThreadID = nil
        // Opening the surface predicts a generate; warm the capture cache.
        screenshotService.prewarmFreshFullScreenCache()
        if isOverlayWindowVisible, overlayFocusTarget == .transcriptView || overlayFocusTarget == nil {
            overlayFocusTarget = .quickAssistQuestion
        }
        ensureActiveQuickAssistThreadLoaded(selectNewest: false)
        refreshQuickAssistThreads(selectThreadID: activeQuickAssistThreadID)

        if clearInputs {
            quickAssistQuestion = ""
            quickAssistExtraContext = ""
            quickAssistExtraContextExpanded = false
            quickAssistStreamingDraft = nil
        }
        if selectedQuickAssistTurnIndex == nil && !quickAssistTurns.isEmpty {
            selectedQuickAssistTurnIndex = quickAssistTurns.count - 1
            if let index = selectedQuickAssistTurnIndex {
                let displayed = displayedQuickAssistResponse(for: quickAssistTurns[index])
                quickAssistResponse = displayed
                rememberQuickAssistStableResponse(
                    displayed,
                    turnID: quickAssistTurns[index].id
                )
            }
        }
        syncQuickAssistSelectedTurnMetadata()
        syncSelectedQuickAssistHistoryThreadID(preferredThreadID: activeQuickAssistThreadID)
        refreshQuickAssistRelatedMemoryContext(trigger: .quickAssistView)
        // Don't auto-regenerate - just show the view with existing response (if any)
    }
    @MainActor
    func focusQuickAssistQuestionInput() {
        showQuickAssist(clearInputs: false)
        overlayFocusTarget = .quickAssistQuestion
        quickAssistQuestionFocusNonce &+= 1
    }
    @MainActor
    func focusQuickAssistHistorySearch() {
        showQuickAssist(clearInputs: false)
        syncSelectedQuickAssistHistoryThreadID(preferredThreadID: activeQuickAssistThreadID)
        overlayFocusTarget = .quickAssistHistorySearch
        quickAssistHistorySearchFocusNonce &+= 1
    }
    func selectNextQuickAssistHistoryThread() {
        guard isQuickAssistViewVisible else { return }
        let visible = filteredQuickAssistThreadSummaries()
        guard !visible.isEmpty else { return }
        quickAssistPendingDeletionThreadID = nil
        overlayFocusTarget = .quickAssistHistoryThreads

        let currentID = quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID
        let currentIndex = visible.firstIndex(where: { $0.id == currentID }) ?? -1
        let nextIndex = min(currentIndex + 1, visible.count - 1)
        quickAssistSelectedHistoryThreadID = visible[nextIndex].id
    }
    func selectPreviousQuickAssistHistoryThread() {
        guard isQuickAssistViewVisible else { return }
        let visible = filteredQuickAssistThreadSummaries()
        guard !visible.isEmpty else { return }
        quickAssistPendingDeletionThreadID = nil
        overlayFocusTarget = .quickAssistHistoryThreads

        let currentID = quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID
        let currentIndex = visible.firstIndex(where: { $0.id == currentID }) ?? visible.count
        let previousIndex = max(currentIndex - 1, 0)
        quickAssistSelectedHistoryThreadID = visible[previousIndex].id
    }
    func openSelectedQuickAssistHistoryThread() {
        guard isQuickAssistViewVisible else { return }
        guard let threadID = quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID else { return }
        quickAssistPendingDeletionThreadID = nil
        openQuickAssistThread(threadID: threadID, showQuickAssistView: true)
    }
}
