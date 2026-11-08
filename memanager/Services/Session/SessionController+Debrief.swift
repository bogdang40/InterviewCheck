import Foundation

extension SessionController {
    var selectedReviewSessionID: String? {
        get { reviewAnalyticsGate.sessionID }
        set { reviewAnalyticsGate.select(newValue) }
    }
    func generateSessionDebrief(sessionID: String? = nil) {
        guard !isGeneratingDebrief else { return }
        let targetSessionID = sessionID ?? session.id.uuidString
        isGeneratingDebrief = true
        debriefError = nil

        Task {
            let transcriptEntries = self.logger.getTranscriptEntries(sessionId: targetSessionID)
            let quickAssistCalls = self.logger.getQuickAssistCallsForSession(sessionId: targetSessionID, limit: 500)
            let coachFindings = self.logger.getCoachFindings(sessionId: targetSessionID)
            let responseCardEvents = self.logger.getWorkstreamTimeline(
                filter: WorkstreamTimelineFilter(sessionId: targetSessionID, includeDebugEvents: true, limit: 120)
            )
            .filter { $0.type == .responseCard }
            let existingDebrief = self.logger.loadSessionDebrief(sessionId: targetSessionID)

            let debrief = await debriefComposer.compose(
                sessionId: targetSessionID,
                transcriptEntries: transcriptEntries,
                quickAssistCalls: quickAssistCalls,
                coachFindings: coachFindings,
                responseCardEvents: responseCardEvents,
                existingDebriefId: existingDebrief?.id
            )

            await MainActor.run {
                if let debrief {
                    self.logger.saveSessionDebrief(debrief)
                    let saved = self.logger.loadSessionDebrief(sessionId: targetSessionID)
                    if selectedReviewSessionID == targetSessionID || (selectedReviewSessionID == nil && targetSessionID == session.id.uuidString) {
                        currentSessionDebrief = saved
                    }
                    let transcriptForCards = targetSessionID == session.id.uuidString ? session.transcriptEntries : []
                    buildPracticeDeckIfNeeded(
                        sessionID: targetSessionID,
                        debrief: saved,
                        transcript: transcriptForCards
                    )
                    debriefMemoryBridge.extractAndStore(debrief: debrief, sessionId: targetSessionID)
                    refreshWorkstreamTimeline()
                } else {
                    if selectedReviewSessionID == targetSessionID || (selectedReviewSessionID == nil && targetSessionID == session.id.uuidString) {
                        debriefError = "The debrief could not be generated. Existing content has been retained. Retry when the provider is available."
                    }
                }
                isGeneratingDebrief = false
            }
        }
    }
    func loadSessionDebrief(sessionID: String) {
        selectedReviewSessionID = sessionID
        debriefError = nil
        currentSessionDebrief = self.logger.loadSessionDebrief(sessionId: sessionID)
    }
    @MainActor
    func buildPracticeDeckIfNeeded(
        sessionID: String,
        debrief: SessionDebrief?,
        transcript: [TranscriptEntry]
    ) {
        guard settings.practiceStudioEnabled,
              let drills = debrief?.drills,
              !drills.isEmpty
        else { return }

        _ = practiceDeckBuilder.build(
            sessionID: sessionID,
            drills: drills,
            transcript: transcript
        )
    }
    @MainActor
    func startPracticeFromDrill(_ drill: SessionDrill) {
        createNewQuickAssistThread()
        showQuickAssist(clearInputs: false)
        quickAssistQuestion = drill.prompt
        quickAssistExtraContextExpanded = true
        quickAssistExtraContext = drill.transcriptSpan
        quickAssistContextStatusMessage = "Practice drill: \(drill.kind.displayLabel)"
        if let relatedThreadId = drill.relatedThreadId {
            workstreamTimelineFilter.threadId = relatedThreadId
        }
    }
}
