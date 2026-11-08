import Foundation

extension SessionController {
    @MainActor
    func deleteQuickAssistThreads(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        guard !isQuickAssistLoading else {
            throw NSError(domain: "ThreadHistory", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for the answer to finish before deleting threads."
            ])
        }
        let deletedActive = activeQuickAssistThreadID.map(ids.contains) ?? false
        try logger.database.deleteQuickAssistThreads(ids: ids)
        for id in ids {
            pinnedMemoryNodeIDsByThread.removeValue(forKey: id)
            quickAssistSelectedModeByThread.removeValue(forKey: id)
            quickAssistLastFamilyByThread.removeValue(forKey: id)
        }
        if let quickAssistExperimentThreadID, ids.contains(quickAssistExperimentThreadID) {
            self.quickAssistExperimentThreadID = nil
            quickAssistExperimentComparison = nil
        }
        if deletedActive {
            resetQuickAssistSessionState()
            workstreamTimelineFilter.threadId = nil
        }
        refreshQuickAssistThreads(selectThreadID: activeQuickAssistThreadID)
        if deletedActive, let threadID = activeQuickAssistThreadID {
            openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        }
        refreshWorkstreamTimeline()
        refreshCoachFindings()
    }
}
