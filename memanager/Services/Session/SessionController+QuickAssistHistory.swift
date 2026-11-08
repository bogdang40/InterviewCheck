import Foundation

extension SessionController {
    func filteredQuickAssistThreadSummaries(queryOverride: String? = nil) -> [QuickAssistThreadSummary] {
        let query = (queryOverride ?? quickAssistHistorySearchQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return quickAssistThreadSummaries }
        let normalizedQuery = query.lowercased()
        return quickAssistThreadSummaries.filter { summary in
            let title = summary.title.lowercased()
            let preview = summary.previewText?.lowercased() ?? ""
            return title.contains(normalizedQuery) || preview.contains(normalizedQuery)
        }
    }
    func syncSelectedQuickAssistHistoryThreadID(preferredThreadID: String? = nil) {
        let visible = filteredQuickAssistThreadSummaries()
        guard !visible.isEmpty else {
            quickAssistSelectedHistoryThreadID = nil
            return
        }

        if let preferredThreadID,
           visible.contains(where: { $0.id == preferredThreadID }) {
            quickAssistSelectedHistoryThreadID = preferredThreadID
            return
        }

        if let selected = quickAssistSelectedHistoryThreadID,
           visible.contains(where: { $0.id == selected }) {
            return
        }

        if let activeThreadID = activeQuickAssistThreadID,
           visible.contains(where: { $0.id == activeThreadID }) {
            quickAssistSelectedHistoryThreadID = activeThreadID
            return
        }

        quickAssistSelectedHistoryThreadID = visible[0].id
    }
    func refreshQuickAssistThreads(selectThreadID: String? = nil) {
        defer {
            refreshWorkstreamTimeline()
            refreshThreadCardMetadata()
        }
        let summaries = workstreamTimelineRepository.loadQuickAssistThreads(limit: quickAssistThreadLimit)
        quickAssistThreadSummaries = summaries
        quickAssistSelectedModeByThread = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, $0.selectedMode) }
        )
        // A reset starts a fresh conversation lazily. Merely refreshing the
        // drawer must not attach its next question to an older global thread.
        if quickAssistStartsFreshThread { return }

        if let selectThreadID,
           summaries.contains(where: { $0.id == selectThreadID }) {
            activeQuickAssistThreadID = selectThreadID
            syncSelectedQuickAssistHistoryThreadID(preferredThreadID: selectThreadID)
            return
        }

        if let activeQuickAssistThreadID,
           summaries.contains(where: { $0.id == activeQuickAssistThreadID }) {
            syncSelectedQuickAssistHistoryThreadID(preferredThreadID: activeQuickAssistThreadID)
            return
        }

        if let first = summaries.first {
            activeQuickAssistThreadID = first.id
            syncSelectedQuickAssistHistoryThreadID(preferredThreadID: first.id)
            return
        }

        // Reading an empty history must not create another empty thread.
        activeQuickAssistThreadID = nil
        quickAssistSelectedHistoryThreadID = nil
    }

    func openQuickAssistThread(threadID: String, showQuickAssistView: Bool = true) {
        quickAssistStartsFreshThread = false
        if isQuickAssistLoading {
            cancelActiveRequest()
        }

        let calls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID)
        let turns = callsToThreadTurns(calls)
        cacheQuickAssistCallMetadata(calls)
        activeQuickAssistExperiment = calls.last?.experimentGroupId.flatMap { self.logger.loadQuickAssistExperiment(id: $0) }
        let selectedMode = resolvedQuickAssistSelectedMode(for: threadID)
        quickAssistSelectedModeByThread[threadID] = selectedMode
        quickAssistSelectedMode = selectedMode
        quickAssistRouteOverrideIntent = selectedMode.preferredIntent
        quickAssistResolvedMode = nil
        pinnedMemoryNodeIDsByThread[threadID] = self.logger.getQuickAssistThreadPins(threadId: threadID)

        activeQuickAssistThreadID = threadID
        quickAssistSelectedHistoryThreadID = threadID
        quickAssistCoordinator.activateThread(id: threadID, turns: turns)
        syncQuickAssistTurnsFromCoordinator(selectNewest: !turns.isEmpty)
        refreshQuickAssistThreads(selectThreadID: threadID)

        if showQuickAssistView {
            revealQuickAssistSurface()
        }
        if isQuickAssistViewVisible, hasQuickAssistScrollableContent {
            activeScrollTarget = .quickAssist
        }
        refreshQuickAssistRelatedMemoryContext(trigger: .threadNavigation)
        workstreamTimelineFilter.threadId = threadID
        refreshWorkstreamTimeline()
        refreshCoachFindings()
    }
    func createNewQuickAssistThread() {
        quickAssistStartsFreshThread = false
        if isQuickAssistLoading {
            cancelActiveRequest()
        }

        let threadID = UUID().uuidString
        self.logger.createQuickAssistThread(
            threadId: threadID,
            title: nil,
            originSessionId: session.id.uuidString,
            selectedMode: .auto
        )
        pinnedMemoryNodeIDsByThread[threadID] = []
        activeQuickAssistThreadID = threadID
        quickAssistSelectedHistoryThreadID = threadID
        quickAssistCoordinator.activateThread(id: threadID, turns: [])
        quickAssistTurns = []
        selectedQuickAssistTurnIndex = nil
        quickAssistResponse = nil
        quickAssistStreamingDraft = nil
        quickAssistLastStableResponse = nil
        quickAssistLastStableTurnID = nil
        quickAssistSelectedMode = .auto
        quickAssistResolvedMode = nil
        quickAssistMemorySnippets = []
        quickAssistRelatedMemorySnippets = []
        quickAssistVerificationRecord = nil
        quickAssistSelectedTurnFeedbackStatus = .none
        quickAssistRecoveryPlan = nil
        quickAssistRouteOverrideIntent = nil
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
        activeQuickAssistExperiment = nil
        quickAssistCallByTurnID = [:]
        quickAssistSelectedModeByThread[threadID] = .auto
        quickAssistQuestion = ""
        quickAssistExtraContext = ""
        quickAssistExtraContextExpanded = false
        quickAssistContextStatusMessage = nil
        refreshQuickAssistThreads(selectThreadID: threadID)

        revealQuickAssistSurface()
        workstreamTimelineFilter.threadId = threadID
        refreshWorkstreamTimeline()
        refreshCoachFindings()
    }
    func deleteQuickAssistThread(threadID: String) {
        if isQuickAssistLoading {
            cancelActiveRequest()
        }

        quickAssistPendingDeletionThreadID = nil
        self.logger.deleteQuickAssistThread(threadId: threadID)
        pinnedMemoryNodeIDsByThread.removeValue(forKey: threadID)
        quickAssistSelectedModeByThread.removeValue(forKey: threadID)
        if quickAssistExperimentThreadID == threadID {
            quickAssistExperimentThreadID = nil
            quickAssistExperimentComparison = nil
        }

        let summaries = workstreamTimelineRepository.loadQuickAssistThreads(limit: quickAssistThreadLimit)
        quickAssistThreadSummaries = summaries

        if summaries.isEmpty {
            bootstrapQuickAssistThreadForCurrentSession()
            return
        }

        let nextThreadID: String
        if threadID == activeQuickAssistThreadID {
            nextThreadID = summaries[0].id
        } else {
            nextThreadID = activeQuickAssistThreadID ?? summaries[0].id
        }
        openQuickAssistThread(threadID: nextThreadID, showQuickAssistView: isQuickAssistViewVisible)
        refreshWorkstreamTimeline()
        refreshCoachFindings()
    }
}
