import Foundation

extension SessionController {
    @MainActor
    func solve() async {
        guard AccessGuard.allows() else {
            errorMessage = AccessGuard.deniedMessage
            return
        }
        guard !isLoading else { return }
        beginSessionHistoryIfNeeded()

        solveTask?.cancel()
        let requestID = UUID()
        activeSolveRequestID = requestID
        isLoading = true
        let sessionID = session.id
        solveTask = Task { [weak self] in
            await self?.runSolve(sessionID: sessionID, requestID: requestID)
        }
        await solveTask?.value
    }
    
    /// Solve using system design mode - uses different prompts optimized for design questions
    @MainActor
    func solveSystemDesign() async {
        guard AccessGuard.allows() else {
            errorMessage = AccessGuard.deniedMessage
            return
        }
        guard !isLoading else { return }
        beginSessionHistoryIfNeeded()
        
        solveTask?.cancel()
        let requestID = UUID()
        activeSolveRequestID = requestID
        isLoading = true
        let sessionID = session.id
        solveTask = Task { [weak self] in
            await self?.runSolveSystemDesign(sessionID: sessionID, requestID: requestID)
        }
        await solveTask?.value
    }
    @MainActor
    @discardableResult
    func applyQuickAssistStreamUpdate(
        _ response: String,
        sessionID: UUID,
        requestID: UUID
    ) -> Bool {
        guard session.id == sessionID,
              activeQuickAssistRequestID == requestID,
              isQuickAssistLoading else {
            return false
        }
        let wasEmpty = quickAssistStreamingDraft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        // Only the streaming draft updates per chunk; quickAssistResponse is
        // written once at settle (and on cancel), halving objectWillChange
        // emissions on the hottest UI path.
        quickAssistStreamingDraft = response
        if wasEmpty && !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.logger.logDebugEvent(
                category: "openai_stream",
                name: "streaming_draft_visible",
                details: "provider=\(settings.selectedProvider.rawValue), chars=\(response.count)"
            )
        }
        return true
    }
    // MARK: - Task Management

    func cancelActiveTasks() {
        if isQuickAssistLoading,
           let draft = quickAssistStreamingDraft,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quickAssistInterruptedAnswer = QuickAssistInterruptedAnswer(
                response: draft,
                question: quickAssistRequestQuestion ?? quickAssistQuestion,
                reason: .cancelled
            )
        }
        solveTask?.cancel()
        solveTask = nil
        quickAssistTask?.cancel()
        quickAssistTask = nil
        mlGuideTask?.cancel()
        mlGuideTask = nil
        activeSolveRequestID = UUID()
        activeQuickAssistRequestID = UUID()
        activeMLGuideRequestID = UUID()
        isLoading = false
        isQuickAssistLoading = false
        // Keep a cancelled stream's partial answer on screen; the draft no
        // longer mirrors into quickAssistResponse during streaming.
        if let draft = quickAssistStreamingDraft,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quickAssistResponse = draft
        }
        quickAssistStreamingDraft = nil
        quickAssistRouteSummary = nil
        quickAssistAnswerFamilyBadge = nil
        isMLGuideLoading = false
        isStreaming = false
        systemDesignRecoveryInProgress = false
        systemDesignStableFallbackActive = false
        self.logger.logSessionUpdated(session: session)
    }
    /// Cancel any active AI request (solve or quick assist) - triggered by Cmd+Shift+.
    func cancelActiveRequest() {
        NSLog("[SessionController] Cancelling active request")
        cancelActiveTasks()
        errorMessage = nil  // Clear any error since user cancelled
    }
}
