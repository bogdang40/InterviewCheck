import Foundation

@MainActor
extension SessionController {
    func setOverlayWindowVisible(_ isVisible: Bool) {
        isOverlayWindowVisible = isVisible
        guard isVisible else {
            overlayFocusTarget = nil
            return
        }
        if overlayFocusTarget == nil {
            overlayFocusTarget = defaultOverlayFocusTarget()
        }
        normalizeOverlaySelectionState()
    }

    var overlayKeyboardStatus: String? {
        guard isOverlayWindowVisible, let overlayFocusTarget else { return nil }
        let selectionText = overlaySelectionSummary(for: overlayFocusTarget)
        if selectionText.isEmpty {
            return overlayFocusTarget.displayName
        }
        return "\(overlayFocusTarget.displayName): \(selectionText)"
    }

    @discardableResult
    func handleOverlayCommand(_ command: OverlayCommand) -> Bool {
        guard isOverlayWindowVisible else { return false }

        if overlayFocusTarget == nil {
            overlayFocusTarget = defaultOverlayFocusTarget()
        }
        normalizeOverlaySelectionState()

        switch command {
        case .nextFocus:
            moveOverlayFocus(step: 1)
            return true
        case .previousFocus:
            moveOverlayFocus(step: -1)
            return true
        case .moveLeft:
            return moveOverlaySelection(horizontalStep: -1)
        case .moveRight:
            return moveOverlaySelection(horizontalStep: 1)
        case .moveUp:
            return moveOverlaySelection(verticalStep: -1)
        case .moveDown:
            return moveOverlaySelection(verticalStep: 1)
        case .activate:
            return activateOverlaySelection()
        case .space:
            return insertTextIfNeeded(" ") || activateOverlaySelection()
        case .dismiss:
            return dismissOverlaySelection()
        case .deleteBackward:
            return deleteBackwardFromFocusedField()
        case .deleteSelection:
            return deleteOverlaySelection()
        case .insertText(let text):
            return insertTextIfNeeded(text)
        }
    }

    func defaultOverlayFocusTarget() -> OverlayFocusTarget {
        if isQuickAssistViewVisible {
            return .quickAssistQuestion
        }
        if isTranscriptViewVisible {
            return .transcriptView
        }
        if activeLiveResponseCard != nil {
            return .liveResponseActions
        }
        return .sectionTabs
    }

    func availableOverlayFocusTargets() -> [OverlayFocusTarget] {
        var targets: [OverlayFocusTarget] = [.sectionTabs]

        if isQuickAssistViewVisible {
            targets.append(.quickAssistQuestion)
            if quickAssistExtraContextExpanded {
                targets.append(.quickAssistExtraContext)
            }
            targets.append(.quickAssistRouteOverride)
            if !quickAssistRelatedMemorySnippets.isEmpty {
                targets.append(.quickAssistRelatedMemory)
            }
            targets.append(.quickAssistHistorySearch)
            if !filteredQuickAssistThreadSummaries().isEmpty {
                targets.append(.quickAssistHistoryThreads)
            }
            if activeLiveResponseCard != nil {
                targets.append(.liveResponseActions)
            }
            targets.append(.quickAssistThreadTools)
        } else if isTranscriptViewVisible {
            targets.append(.transcriptView)
        } else if activeLiveResponseCard != nil {
            targets.append(.liveResponseActions)
        }

        if SettingsManager.shared.showDiagnosticsOverlay {
            targets.append(.diagnosticsActions)
        }

        return targets
    }

    func moveOverlayFocus(step: Int) {
        let targets = availableOverlayFocusTargets()
        guard !targets.isEmpty else { return }
        let currentIndex = overlayFocusTarget.flatMap { targets.firstIndex(of: $0) } ?? 0
        let nextIndex = (currentIndex + step + targets.count) % targets.count
        overlayFocusTarget = targets[nextIndex]
        if overlayFocusTarget == .quickAssistRouteOverride {
            overlaySelectionState.routeOverrideIndex = overlayThreadModeOptions()
                .firstIndex(of: quickAssistSelectedMode) ?? 0
        }
        normalizeOverlaySelectionState()
    }

    func moveOverlaySelection(horizontalStep: Int = 0, verticalStep: Int = 0) -> Bool {
        guard let overlayFocusTarget else { return false }

        switch overlayFocusTarget {
        case .sectionTabs:
            if horizontalStep > 0 {
                nextSection()
                return true
            }
            if horizontalStep < 0 {
                previousSection()
                return true
            }
            return false
        case .quickAssistRouteOverride:
            let options = overlayThreadModeOptions()
            guard !options.isEmpty else { return false }
            let step = horizontalStep != 0 ? horizontalStep : verticalStep
            guard step != 0 else { return false }
            overlaySelectionState.routeOverrideIndex = clampWrappedIndex(
                overlaySelectionState.routeOverrideIndex + step,
                upperBound: options.count
            )
            return true
        case .quickAssistRelatedMemory:
            guard !quickAssistRelatedMemorySnippets.isEmpty else { return false }
            let step = horizontalStep != 0 ? horizontalStep : verticalStep
            guard step != 0 else { return false }
            overlaySelectionState.relatedMemoryIndex = clampWrappedIndex(
                overlaySelectionState.relatedMemoryIndex + step,
                upperBound: quickAssistRelatedMemorySnippets.count
            )
            return true
        case .quickAssistHistoryThreads:
            if verticalStep > 0 {
                selectNextQuickAssistHistoryThread()
                return true
            }
            if verticalStep < 0 {
                selectPreviousQuickAssistHistoryThread()
                return true
            }
            return false
        case .quickAssistThreadTools:
            let actions = overlayThreadToolActions()
            guard !actions.isEmpty else { return false }
            let step = horizontalStep != 0 ? horizontalStep : verticalStep
            guard step != 0 else { return false }
            overlaySelectionState.threadToolActionIndex = clampWrappedIndex(
                overlaySelectionState.threadToolActionIndex + step,
                upperBound: actions.count
            )
            return true
        case .liveResponseActions:
            let actions = overlayLiveResponseActions()
            guard !actions.isEmpty else { return false }
            let step = horizontalStep != 0 ? horizontalStep : verticalStep
            guard step != 0 else { return false }
            overlaySelectionState.liveResponseActionIndex = clampWrappedIndex(
                overlaySelectionState.liveResponseActionIndex + step,
                upperBound: actions.count
            )
            return true
        case .diagnosticsActions:
            let actions = OverlayDiagnosticsAction.allCases
            let step = horizontalStep != 0 ? horizontalStep : verticalStep
            guard step != 0 else { return false }
            overlaySelectionState.diagnosticsActionIndex = clampWrappedIndex(
                overlaySelectionState.diagnosticsActionIndex + step,
                upperBound: actions.count
            )
            return true
        case .quickAssistQuestion, .quickAssistExtraContext, .quickAssistHistorySearch, .transcriptView:
            return false
        }
    }

    func overlaySelectionSummary(for target: OverlayFocusTarget) -> String {
        switch target {
        case .sectionTabs:
            return String(describing: currentSection)
        case .quickAssistQuestion:
            return quickAssistQuestion.isEmpty ? "Ready to type" : "\(quickAssistQuestion.count) chars"
        case .quickAssistExtraContext:
            return quickAssistExtraContextExpanded
                ? "\(quickAssistExtraContext.count) chars"
                : "Collapsed"
        case .quickAssistRouteOverride:
            let options = overlayThreadModeOptions()
            guard options.indices.contains(overlaySelectionState.routeOverrideIndex) else { return "" }
            return options[overlaySelectionState.routeOverrideIndex].displayName
        case .quickAssistRelatedMemory:
            guard quickAssistRelatedMemorySnippets.indices.contains(overlaySelectionState.relatedMemoryIndex) else { return "" }
            let snippet = quickAssistRelatedMemorySnippets[overlaySelectionState.relatedMemoryIndex]
            return snippet.isPinned ? "Pinned" : "Ready to pin"
        case .quickAssistHistorySearch:
            return quickAssistHistorySearchQuery.isEmpty ? "Ready to type" : quickAssistHistorySearchQuery
        case .quickAssistHistoryThreads:
            if let pendingDeletionID = quickAssistPendingDeletionThreadID,
               pendingDeletionID == (quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID) {
                return "Press Return to confirm delete"
            }
            return quickAssistSelectedHistoryThreadID ?? activeQuickAssistThreadID ?? "No thread"
        case .quickAssistThreadTools:
            let actions = overlayThreadToolActions()
            guard actions.indices.contains(overlaySelectionState.threadToolActionIndex) else { return "" }
            return actions[overlaySelectionState.threadToolActionIndex].displayName
        case .liveResponseActions:
            let actions = overlayLiveResponseActions()
            guard actions.indices.contains(overlaySelectionState.liveResponseActionIndex) else { return "" }
            return actions[overlaySelectionState.liveResponseActionIndex].displayName
        case .transcriptView:
            return "Press Return or Escape to close"
        case .diagnosticsActions:
            let actions = OverlayDiagnosticsAction.allCases
            guard actions.indices.contains(overlaySelectionState.diagnosticsActionIndex) else { return "" }
            return actions[overlaySelectionState.diagnosticsActionIndex].displayName
        }
    }

    func overlayThreadToolActions() -> [OverlayThreadToolAction] {
        var actions: [OverlayThreadToolAction] = []

        if activeQuickAssistExperiment?.candidates.isEmpty == false {
            actions.append(.compareExperiment)
            if activeQuickAssistExperiment?.candidates.contains(where: \.isWinner) == true {
                actions.append(.adoptWinner)
            }
            actions.append(.clearExperiment)
        } else if !quickAssistTurns.isEmpty {
            actions.append(.branch)
        }

        if activeQuickAssistThreadID != nil {
            actions.append(.timeline)
        }

        return actions
    }

    func overlayLiveResponseActions() -> [OverlayLiveResponseAction] {
        activeLiveResponseCard == nil ? [] : OverlayLiveResponseAction.allCases
    }

    func overlayThreadModeOptions() -> [QuickAssistThreadMode] {
        QuickAssistThreadMode.allCases
    }

    func normalizeOverlaySelectionState() {
        let routeOptions = overlayThreadModeOptions()
        overlaySelectionState.routeOverrideIndex = clampWrappedIndex(
            overlaySelectionState.routeOverrideIndex, upperBound: routeOptions.count
        )

        if quickAssistRelatedMemorySnippets.isEmpty {
            overlaySelectionState.relatedMemoryIndex = 0
        } else {
            overlaySelectionState.relatedMemoryIndex = min(
                overlaySelectionState.relatedMemoryIndex,
                quickAssistRelatedMemorySnippets.count - 1
            )
        }

        let threadToolActions = overlayThreadToolActions()
        if threadToolActions.isEmpty {
            overlaySelectionState.threadToolActionIndex = 0
        } else {
            overlaySelectionState.threadToolActionIndex = min(
                overlaySelectionState.threadToolActionIndex,
                threadToolActions.count - 1
            )
        }

        let liveResponseActions = overlayLiveResponseActions()
        if liveResponseActions.isEmpty {
            overlaySelectionState.liveResponseActionIndex = 0
        } else {
            overlaySelectionState.liveResponseActionIndex = min(
                overlaySelectionState.liveResponseActionIndex,
                liveResponseActions.count - 1
            )
        }

        overlaySelectionState.diagnosticsActionIndex = min(
            overlaySelectionState.diagnosticsActionIndex,
            OverlayDiagnosticsAction.allCases.count - 1
        )
    }

    func clampWrappedIndex(_ value: Int, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return (value % upperBound + upperBound) % upperBound
    }

}
