import Foundation

extension SessionController {
    func refreshWorkstreamTimeline() {
        if workstreamTimelineFilter.sessionId == nil,
           workstreamTimelineFilter.threadId == nil {
            workstreamTimelineFilter.sessionId = session.id.uuidString
        }
        // The timeline load runs 11 sequential queries (several full-scan
        // LIKEs); it used to block the calling (main) thread. Load on a
        // background task; a generation counter drops stale results when
        // refreshes overlap.
        workstreamTimelineLoadGeneration += 1
        let generation = workstreamTimelineLoadGeneration
        let filter = workstreamTimelineFilter
        let repository = workstreamTimelineRepository
        Task.detached(priority: .userInitiated) { [weak self] in
            let events = repository.loadTimeline(filter: filter)
            guard let self else { return }
            await MainActor.run {
                guard self.workstreamTimelineLoadGeneration == generation else { return }
                self.workstreamTimelineEvents = events
                if let selected = self.selectedWorkstreamTimelineEventID,
                   !events.contains(where: { $0.id == selected }) {
                    self.selectedWorkstreamTimelineEventID = nil
                }
            }
        }
    }
    func inspectThreadInTimeline(threadID: String) {
        workstreamTimelineFilter.threadId = threadID
        if let summary = quickAssistThreadSummaries.first(where: { $0.id == threadID }),
           let originSession = summary.originSessionId {
            workstreamTimelineFilter.sessionId = originSession
        }
        refreshWorkstreamTimeline()
    }
    func clearWorkstreamTimelineThreadFilter() {
        workstreamTimelineFilter.threadId = nil
        refreshWorkstreamTimeline()
    }
    func openWorkstreamTimelineEvent(_ event: WorkstreamTimelineEvent) {
        selectedWorkstreamTimelineEventID = event.id
        if let threadId = event.threadId, !threadId.isEmpty {
            openQuickAssistThread(threadID: threadId, showQuickAssistView: true)
            if let turnId = event.turnId,
               let targetIndex = quickAssistTurns.firstIndex(where: { $0.id.uuidString == turnId }) {
                selectQuickAssistTurn(index: targetIndex)
            }
            return
        }
        if let sessionId = event.sessionId {
            workstreamTimelineFilter.sessionId = sessionId
            refreshWorkstreamTimeline()
        }
    }
    func compareQuickAssistThreads(
        leftThreadID: String,
        rightThreadID: String
    ) -> WorkstreamThreadComparison? {
        guard let leftSummary = quickAssistThreadSummaries.first(where: { $0.id == leftThreadID }),
              let rightSummary = quickAssistThreadSummaries.first(where: { $0.id == rightThreadID }) else {
            return nil
        }
        let leftCalls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: leftThreadID)
        let rightCalls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: rightThreadID)
        let leftMetrics = workstreamTimelineComposer.buildThreadMetrics(summary: leftSummary, calls: leftCalls)
        let rightMetrics = workstreamTimelineComposer.buildThreadMetrics(summary: rightSummary, calls: rightCalls)
        workstreamCompareLeftThreadID = leftThreadID
        workstreamCompareRightThreadID = rightThreadID
        return workstreamTimelineComposer.compareThreads(left: leftMetrics, right: rightMetrics)
    }
}
