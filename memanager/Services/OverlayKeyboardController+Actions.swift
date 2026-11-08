import Foundation

@MainActor
extension SessionController {
    func activateOverlaySelection() -> Bool {
        normalizeOverlaySelectionState()

        guard let overlayFocusTarget else { return false }
        switch overlayFocusTarget {
        case .sectionTabs:
            return true
        case .quickAssistQuestion:
            let trimmedQuestion = quickAssistQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuestion.isEmpty else { return false }
            quickAssist()
            return true
        case .quickAssistExtraContext:
            if !quickAssistExtraContextExpanded {
                quickAssistExtraContextExpanded = true
            }
            return true
        case .quickAssistRouteOverride:
            let options = overlayThreadModeOptions()
            guard options.indices.contains(overlaySelectionState.routeOverrideIndex) else { return false }
            setQuickAssistThreadMode(options[overlaySelectionState.routeOverrideIndex])
            return true
        case .quickAssistRelatedMemory:
            guard quickAssistRelatedMemorySnippets.indices.contains(overlaySelectionState.relatedMemoryIndex) else { return false }
            toggleQuickAssistMemoryPin(quickAssistRelatedMemorySnippets[overlaySelectionState.relatedMemoryIndex].id)
            return true
        case .quickAssistHistorySearch:
            openSelectedQuickAssistHistoryThread()
            return true
        case .quickAssistHistoryThreads:
            if let pendingDeletionID = quickAssistPendingDeletionThreadID,
               pendingDeletionID == (quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID) {
                confirmPendingQuickAssistHistoryDeletion()
            } else {
                openSelectedQuickAssistHistoryThread()
            }
            return true
        case .quickAssistThreadTools:
            return activateThreadToolAction()
        case .liveResponseActions:
            return activateLiveResponseAction()
        case .transcriptView:
            hideTranscriptLog()
            return true
        case .diagnosticsActions:
            return activateDiagnosticsAction()
        }
    }

    func dismissOverlaySelection() -> Bool {
        if quickAssistPendingDeletionThreadID != nil {
            cancelPendingQuickAssistHistoryDeletion()
            return true
        }

        if SettingsManager.shared.showDiagnosticsOverlay,
           overlayFocusTarget == .diagnosticsActions {
            SettingsManager.shared.showDiagnosticsOverlay = false
            overlayFocusTarget = defaultOverlayFocusTarget()
            return true
        }

        if isTranscriptViewVisible {
            hideTranscriptLog()
            overlayFocusTarget = defaultOverlayFocusTarget()
            return true
        }

        return false
    }

    func deleteBackwardFromFocusedField() -> Bool {
        guard let overlayFocusTarget else { return false }

        switch overlayFocusTarget {
        case .quickAssistQuestion:
            guard !quickAssistQuestion.isEmpty else { return false }
            quickAssistQuestion.removeLast()
            return true
        case .quickAssistExtraContext:
            guard !quickAssistExtraContext.isEmpty else { return false }
            quickAssistExtraContext.removeLast()
            return true
        case .quickAssistHistorySearch:
            guard !quickAssistHistorySearchQuery.isEmpty else { return false }
            quickAssistHistorySearchQuery.removeLast()
            return true
        default:
            return false
        }
    }

    func deleteOverlaySelection() -> Bool {
        guard overlayFocusTarget == .quickAssistHistoryThreads else { return false }
        promptDeleteSelectedQuickAssistHistoryThread()
        return quickAssistPendingDeletionThreadID != nil
    }

    func insertTextIfNeeded(_ text: String) -> Bool {
        guard let overlayFocusTarget else { return false }
        guard !text.isEmpty else { return false }

        switch overlayFocusTarget {
        case .quickAssistQuestion:
            showQuickAssist(clearInputs: false)
            quickAssistQuestion.append(text)
            return true
        case .quickAssistExtraContext:
            showQuickAssist(clearInputs: false)
            quickAssistExtraContextExpanded = true
            quickAssistExtraContext.append(text)
            return true
        case .quickAssistHistorySearch:
            showQuickAssist(clearInputs: false)
            quickAssistHistorySearchQuery.append(text)
            return true
        default:
            return false
        }
    }

    func activateThreadToolAction() -> Bool {
        let actions = overlayThreadToolActions()
        guard actions.indices.contains(overlaySelectionState.threadToolActionIndex) else { return false }

        switch actions[overlaySelectionState.threadToolActionIndex] {
        case .branch:
            createQuickAssistExperimentFromSelectedTurn()
        case .timeline:
            guard let activeQuickAssistThreadID else { return false }
            inspectThreadInTimeline(threadID: activeQuickAssistThreadID)
        case .compareExperiment:
            compareQuickAssistExperiment()
        case .adoptWinner:
            guard let winnerThreadID = activeQuickAssistExperiment?.candidates.first(where: \.isWinner)?.threadId else {
                return false
            }
            adoptQuickAssistBranch(threadID: winnerThreadID)
        case .clearExperiment:
            clearQuickAssistExperiment()
        }

        return true
    }

    func activateLiveResponseAction() -> Bool {
        let actions = overlayLiveResponseActions()
        guard actions.indices.contains(overlaySelectionState.liveResponseActionIndex) else { return false }

        switch actions[overlaySelectionState.liveResponseActionIndex] {
        case .cycle:
            cycleLiveResponseCard()
        case .pin:
            pinActiveResponseCardToTeleprompter()
        case .refine:
            refineActiveResponseCard()
        case .dismiss:
            dismissLiveResponseCard()
        }

        return true
    }

    func activateDiagnosticsAction() -> Bool {
        let actions = OverlayDiagnosticsAction.allCases
        guard actions.indices.contains(overlaySelectionState.diagnosticsActionIndex) else { return false }

        switch actions[overlaySelectionState.diagnosticsActionIndex] {
        case .retrySystemStream:
            AudioCaptureService.shared.retrySystemStream()
        case .refreshPermissions:
            PermissionManager.shared.refreshAllStatuses()
        case .close:
            SettingsManager.shared.showDiagnosticsOverlay = false
        }

        return true
    }

    func promptDeleteSelectedQuickAssistHistoryThread() {
        guard let threadID = quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID else { return }
        quickAssistPendingDeletionThreadID = threadID
        quickAssistContextStatusMessage = "Press Return to confirm deleting the selected Quick Assist thread. Press Escape to cancel."
    }

    func confirmPendingQuickAssistHistoryDeletion() {
        guard let threadID = quickAssistPendingDeletionThreadID else { return }
        deleteQuickAssistThread(threadID: threadID)
        quickAssistPendingDeletionThreadID = nil
        quickAssistContextStatusMessage = "Deleted the selected Quick Assist thread."
    }

    func cancelPendingQuickAssistHistoryDeletion() {
        quickAssistPendingDeletionThreadID = nil
        quickAssistContextStatusMessage = "Canceled Quick Assist thread deletion."
    }
}
