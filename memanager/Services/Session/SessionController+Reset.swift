import Foundation

extension SessionController {
    @MainActor
    func resetQuickAssistSessionState() {
        invalidateThreadCardMetadata()
        threadCardMetadataMap = [:]
        quickAssistStartsFreshThread = false
        quickAssistPendingDeletionThreadID = nil
        markQuickAssistFlowEventsChanged()
        quickAssistToolCallEvents = []
        quickAssistReasoningEvents = []
        quickAssistSelectedToolTrace = nil
        quickAssistSelectedReasoningFlow = nil
        quickAssistCoordinator.resetForNewSession()
        quickAssistTurns = []
        selectedQuickAssistTurnIndex = nil
        quickAssistResponse = nil
        quickAssistStreamingDraft = nil
        quickAssistLastStableResponse = nil
        quickAssistInterruptedAnswer = nil
        quickAssistRequestQuestion = nil
        quickAssistLastStableTurnID = nil
        quickAssistQuestion = ""
        quickAssistExtraContext = ""
        quickAssistExtraContextExpanded = false
        quickAssistContextStatusMessage = nil
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
        quickAssistThreadSummaries = []
        activeQuickAssistThreadID = nil
        quickAssistSelectedHistoryThreadID = nil
        quickAssistHistorySearchQuery = ""
        quickAssistSelectedModeByThread = [:]
        quickAssistLastFamilyByThread = [:]
        quickAssistCallByTurnID = [:]
        pinnedMemoryNodeIDsByThread = [:]
        selectedWorkstreamTimelineEventID = nil
        workstreamCompareLeftThreadID = nil
        workstreamCompareRightThreadID = nil
        activeCoachFindings = []
    }
    @MainActor
    func prepareForNewSession() {
        invalidateSessionCardMetadata()
        isRestoredSessionAwaitingStart = false
        // Log previous session end if there was one
        if session.startedAt != nil, self.logger.isLoggingSession(session.id) {
            self.logger.logSessionEnded(sessionId: session.id)
        }

        session.reset()
        resetSolvePresentation()
        resetQuickAssistSessionState()
        quickAssistStartsFreshThread = true
        currentSessionDebrief = nil
        activeScrollTarget = .main
        activeInterviewMoment = nil
        liveResponseCards = []
        activeLiveResponseCardIndex = 0
        teleprompterPinnedResponseCard = nil

        screenshotService.clearAll()

        errorMessage = nil
        quickAssistQuestionFocusNonce = 0
        quickAssistHistorySearchFocusNonce = 0
        activeHubNudge = nil
        isQuickAssistLoading = false
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        
        // Reset Quick Assist state for new session
        interviewSignalEngine.reset()
        PacingDirector.shared.reset()

        // Load cross-session context for the new session
        sessionFocusContext = sessionFocusLoader.loadFocusForNewSession()
        cachedSkillReport = skillProgressionTracker.buildReport(currentSessionId: session.id.uuidString)
        lastQuickAssistMemoryNodeID = nil
        lastSolveMemoryNodeID = nil
        lastCoachEvaluationAt = nil
        
        // Reset ML Guide state for new session
        mlGuideResponse = nil
        isMLGuideLoading = false
        isMLGuideViewVisible = false
        mlGuideQuestion = ""
        mlGuideExtraContext = ""
        lastSuccessfulMLGuideResponse = nil
        lastMLGuideTimestamp = nil
        datasetSummary = nil  // Will reload on next ML Guide call
        datasetSummaryLoadAttempted = false
        
        workstreamTimelineFilter = WorkstreamTimelineFilter(
            sessionId: session.id.uuidString,
            threadId: nil,
            searchQuery: "",
            includeDebugEvents: true,
            limit: 160
        )
        refreshWorkstreamTimeline()
        refreshCoachFindings()
    }
    @MainActor
    func resetSolvePresentation() {
        activeSolveRequestID = UUID()
        isLoading = false
        isStreaming = false
        streamingResponseText = ""
        currentSection = .problem
        expandedImplementationStep = 1
        implementationStepCount = 0
        currentChunkIndex = 0
        totalChunkCount = 0
        canvasParser.reset()
        canvasDirector.reset()
        canvasScene = .empty
        systemDesignContextStatusMessage = nil
        systemDesignSectionIndex = 0
        systemDesignSectionCount = 0
        systemDesignStepIndexBySection = [:]
        systemDesignCompletenessReport = nil
        systemDesignRecoveryInProgress = false
        systemDesignStableFallbackActive = false
        updateSessionResponse(nil)
    }
}
