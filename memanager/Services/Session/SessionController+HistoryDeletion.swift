import Foundation

extension SessionController {
    var activeHistorySessionID: String? {
        logger.state.sessionId ?? (session.state != .idle ? session.id.uuidString : nil)
    }

    func sessionDeletionUnavailableReason(id: String) -> String? {
        if logger.state.sessionId == id || (session.id.uuidString == id && (session.state != .idle || audioService.captureState != .idle)) {
            return "End this session before deleting it."
        }
        if isLoading || isQuickAssistLoading || isGeneratingDebrief || isMLGuideLoading {
            return "Wait for generation to finish before deleting a session."
        }
        return nil
    }

    @MainActor
    func deleteHistorySession(id: String) throws {
        try deleteHistorySessions(ids: [id])
    }

    @MainActor
    func deleteHistorySessions(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let reason = sessionDeletionUnavailableReason(id: id) {
                throw NSError(domain: "SessionHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
        }
        let affectedActiveThread = activeQuickAssistThreadID.map { threadID in
            workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID).contains { ids.contains($0.sessionId) }
        } ?? false
        try logger.database.deleteSessions(ids: ids)
        invalidateSessionCardMetadata()
        // Invalidate pending analytics before clearing the selected detail.
        if let selectedReviewSessionID, ids.contains(selectedReviewSessionID) {
            self.selectedReviewSessionID = nil
            currentSessionDebrief = nil
            currentSessionMetrics = nil
            currentSkillReport = .empty
            currentProviderBreakdown = []
        }
        if ids.contains(session.id.uuidString) {
            session.reset()
            resetSolvePresentation()
            audioService.clearTranscript()
            screenshotService.clearAll()
        }
        for id in ids { sessionCardMetadataMap.removeValue(forKey: id) }
        if affectedActiveThread { resetQuickAssistSessionState() }
        refreshQuickAssistThreads(selectThreadID: activeQuickAssistThreadID)
        if affectedActiveThread, let threadID = activeQuickAssistThreadID {
            openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        }
        quickAssistMemorySnippets = []
        quickAssistRelatedMemorySnippets = []
        lastQuickAssistMemoryNodeID = nil
        lastSolveMemoryNodeID = nil
        refreshCoachFindings()
        refreshWorkstreamTimeline()
    }
}
