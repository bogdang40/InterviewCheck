import Foundation

extension SessionController {
    func syncSessionState(with captureState: AudioCaptureService.CaptureState) {
        switch captureState {
        case .recording:
            isRestoredSessionAwaitingStart = false
            if session.startedAt == nil {
                session.startedAt = Date()
            }
            session.state = .listening
            beginSessionHistoryIfNeeded()
        case .starting:
            session.state = .listening
        case .paused, .pausing:
            session.state = .paused
        case .idle, .stopping:
            session.state = isRestoredSessionAwaitingStart ? .paused : .idle
        }
        // Idle may follow a deliberate transcript clear while replacing a
        // session. Persist stable recording/pause state, and save End explicitly.
        if captureState == .recording || captureState == .paused {
            self.logger.logSessionUpdated(session: session)
        }
    }
    // MARK: - Session Control

    func startSession() {
        sessionControlTask?.cancel()
        sessionControlTask = Task { @MainActor in
            await startSessionAsync()
        }
    }
    func resetSession() {
        sessionControlTask?.cancel()
        sessionControlTask = Task { @MainActor in
            await resetSessionAsync()
        }
    }
    func togglePauseSession() {
        let now = Date().timeIntervalSince1970
        guard now - lastPauseToggleTime >= pauseToggleCooldown else { return }
        lastPauseToggleTime = now

        switch audioService.captureState {
        case .recording, .starting:
            audioService.pauseCapture()
        case .paused, .pausing:
            audioService.resumeCapture()
        case .idle, .stopping:
            if audioService.captureState == .idle, isRestoredSessionAwaitingStart {
                startSession()
            }
            return
        }
    }
    func endSession() {
        sessionControlTask?.cancel()
        sessionControlTask = Task { @MainActor in
            await endSessionAsync()
        }
    }
    /// Public entry point for the Resume Session button. Rehydrates session state from SQLite
    /// and leaves the saved session paused while audio stays idle until an explicit start.
    @MainActor
    func resumeSession(sessionID: UUID) {
        sessionControlTask?.cancel()
        sessionControlTask = Task { @MainActor in
            await resumeSessionAsync(sessionID: sessionID)
        }
    }
    @MainActor
    func resumeSessionAsync(sessionID: UUID) async {
        guard !Task.isCancelled else { return }
        guard sessionResumeService.resumePayload(sessionID: sessionID) != nil else {
            errorMessage = "That session could not be resumed."
            return
        }
        cancelActiveTasks()
        let stopped = await stopAudioBeforeReplacingSession(clearTranscript: false)
        guard !Task.isCancelled else { return }
        guard stopped else {
            errorMessage = "Timed out stopping audio capture"
            return
        }
        guard let payload = sessionResumeService.resumePayload(sessionID: sessionID) else {
            errorMessage = "That session could not be resumed."
            return
        }
        guard audioService.restoreTranscriptForResume(payload.transcript, entries: payload.transcriptEntries) else {
            errorMessage = "Audio capture must stop before restoring a session."
            return
        }
        if session.startedAt != nil, session.id != payload.sessionID,
           self.logger.isLoggingSession(session.id) {
            self.logger.logSessionEnded(sessionId: session.id)
        }
        session.reset()
        resetSolvePresentation()
        session.id = payload.sessionID
        session.startedAt = payload.startedAt
        session.transcript = payload.transcript
        session.transcriptEntries = payload.transcriptEntries
        session.activeModeSnapshotID = payload.activeModeSnapshotID
        session.state = .paused
        isRestoredSessionAwaitingStart = true
        self.logger.logSessionResumed(sessionId: payload.sessionID)
        resetQuickAssistSessionState()
        workstreamTimelineFilter = WorkstreamTimelineFilter(
            sessionId: payload.sessionID.uuidString,
            threadId: nil,
            searchQuery: "",
            includeDebugEvents: true,
            limit: 160
        )
        if let threadID = payload.quickAssistThreadID {
            workstreamTimelineFilter.threadId = threadID
            openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        } else {
            bootstrapQuickAssistThreadForCurrentSession()
        }
        currentSessionDebrief = self.logger.loadSessionDebrief(sessionId: payload.sessionID.uuidString)
        currentSessionMetrics = nil
        errorMessage = nil
    }
    @MainActor
    func startSessionAsync() async {
        guard !Task.isCancelled else { return }
        switch audioService.captureState {
        case .paused, .pausing:
            startAudioCapture(.resume)
            return
        case .recording, .starting:
            return
        case .idle, .stopping:
            if audioService.captureState == .idle, isRestoredSessionAwaitingStart {
                startAudioCapture(.restoredSession)
                return
            }
            cancelActiveTasks()
            let stopped = await stopAudioBeforeReplacingSession()
            guard !Task.isCancelled else { return }
            if !stopped {
                errorMessage = "Timed out stopping audio capture"
                return
            }
            prepareForNewSession()
            startAudioCapture(.newSession)
        }
    }
    @MainActor
    private func resetSessionAsync() async {
        guard !Task.isCancelled else { return }
        cancelActiveTasks()
        let stopped = await stopAudioBeforeReplacingSession()
        guard !Task.isCancelled else { return }
        if !stopped {
            errorMessage = "Timed out stopping audio capture"
            return
        }
        prepareForNewSession()
    }
    @MainActor
    private func stopAudioBeforeReplacingSession(clearTranscript: Bool = true) async -> Bool {
        guard !Task.isCancelled, await audioService.stopCaptureAndWait(clearTranscript: false),
              !Task.isCancelled else { return false }
        // Only the active logger owns this snapshot. An ended/restored view must
        // never overwrite saved text with the cleared state of an idle service.
        if self.logger.isLoggingSession(session.id) {
            session.transcript = audioService.transcript
            session.transcriptEntries = audioService.transcriptEntries
            session.state = .idle
            self.logger.logSessionUpdated(session: session)
        }
        if clearTranscript { audioService.clearTranscript() }
        return true
    }
    @MainActor
    private func endSessionAsync() async {
        guard !Task.isCancelled else { return }
        cancelActiveTasks()
        let stopped = await audioService.stopCaptureAndWait(clearTranscript: false)
        guard !Task.isCancelled else { return }
        guard stopped else {
            errorMessage = "Timed out stopping audio capture"
            return
        }
        
        // The stop can finalize transcript data before Combine publishes its
        // queued updates. Save the audio service's settled values explicitly.
        session.transcript = audioService.transcript
        session.transcriptEntries = audioService.transcriptEntries
        session.state = .idle
        isRestoredSessionAwaitingStart = false
        self.logger.logSessionUpdated(session: session)
        // Log session end
        self.logger.logSessionEnded(sessionId: session.id)
        if settings.sessionAutoDebriefEnabled {
            generateSessionDebrief(sessionID: session.id.uuidString)
        } else {
            currentSessionDebrief = self.logger.loadSessionDebrief(sessionId: session.id.uuidString)
            buildPracticeDeckIfNeeded(
                sessionID: session.id.uuidString,
                debrief: currentSessionDebrief,
                transcript: session.transcriptEntries
            )
        }

        // Kick off the LLM generated session summary. Runs detached so the end path is not
        // blocked. Result is persisted to SQLite and loaded by the Session Summary UI.
        let endedSessionID = session.id
        Task.detached(priority: .utility) {
            await SessionSummaryComposer.shared.generate(sessionID: endedSessionID)
        }

        session.state = .idle
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        quickAssistQuestion = ""
        quickAssistExtraContext = ""
        quickAssistExtraContextExpanded = false
        quickAssistContextStatusMessage = nil
        quickAssistStreamingDraft = nil
        quickAssistLastStableResponse = nil
        quickAssistLastStableTurnID = nil
        quickAssistSelectedMode = .auto
        quickAssistResolvedMode = nil
        quickAssistRouteSummary = nil
        quickAssistAnswerFamilyBadge = nil
        quickAssistRouteOverrideIntent = nil
        quickAssistMemorySnippets = []
        quickAssistRelatedMemorySnippets = []
        quickAssistVerificationRecord = nil
        quickAssistSelectedTurnFeedbackStatus = .none
        quickAssistRecoveryPlan = nil
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
        activeQuickAssistExperiment = nil
        quickAssistCallByTurnID = [:]
        quickAssistSelectedModeByThread = [:]
        quickAssistLastFamilyByThread = [:]
        quickAssistHistorySearchQuery = ""
        quickAssistSelectedHistoryThreadID = nil
        activeHubNudge = nil
        activeInterviewMoment = nil
        liveResponseCards = []
        teleprompterPinnedResponseCard = nil
        activeCoachFindings = []
        selectedWorkstreamTimelineEventID = nil
        workstreamCompareLeftThreadID = nil
        workstreamCompareRightThreadID = nil
        activeScrollTarget = .main
    }
}
