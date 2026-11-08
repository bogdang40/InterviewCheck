import Foundation

extension SessionController {
    private func forceDisableMLGuideState() {
        mlGuideTask?.cancel()
        mlGuideTask = nil
        activeMLGuideRequestID = UUID()
        isMLGuideLoading = false
        isMLGuideViewVisible = false
        mlGuideResponse = nil
    }
    // MARK: - ML Guide (EDA and Modeling Copilot)

    /// Show the ML Guide view.
    func showMLGuide(clearInputs: Bool = false) {
        guard !isMLGuideTemporarilyDisabled else {
            forceDisableMLGuideState()
            return
        }
        isMLGuideViewVisible = true
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        activeScrollTarget = .mlGuide

        if clearInputs {
            mlGuideQuestion = ""
            mlGuideExtraContext = ""
            mlGuideResponse = nil
        }
    }
    
    /// Generate a new ML Guide response.
    /// This is a fresh start - clears previous context
    func triggerMLGuide() {
        guard !isMLGuideTemporarilyDisabled else {
            forceDisableMLGuideState()
            return
        }
        isMLGuideViewVisible = true
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        activeScrollTarget = .mlGuide
        // Fresh start - clear previous response but KEEP timestamp
        lastSuccessfulMLGuideResponse = nil
        mlGuide(isFollowUp: false)
    }
    
    /// Generate a follow-up ML Guide response.
    /// Includes the previous ML Guide response in context for continuation
    func triggerMLGuideFollowUp() {
        guard !isMLGuideTemporarilyDisabled else {
            forceDisableMLGuideState()
            return
        }
        isMLGuideViewVisible = true
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        activeScrollTarget = .mlGuide
        mlGuide(isFollowUp: true)
    }
    func mlGuide(isFollowUp: Bool = false) {
        guard !isMLGuideTemporarilyDisabled else {
            forceDisableMLGuideState()
            return
        }
        guard !isMLGuideLoading else { return }

        mlGuideTask?.cancel()
        activeMLGuideRequestID = UUID()
        let sessionID = session.id
        let providerType = settings.selectedProvider

        // Filter transcript to entries after last ML Guide
        let transcript = buildTranscriptSinceLastMLGuide()
        let previousResponse = isFollowUp ? lastSuccessfulMLGuideResponse : nil
        
        let freshScreenshot = screenshotService.captureFullScreenBase64()
        let screenshots = freshScreenshot.map { [$0] } ?? []
        let questionSnapshot = mlGuideQuestion
        let extraContextSnapshot = mlGuideExtraContext
        let realtimePrompt = settings.activeMLGuidePromptText()
        let trimmedQuestion = mlGuideQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = mlGuideExtraContext.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // For ML Guide, we can proceed with transcript/question/context even if profiler data is unavailable.
        let hasDataset = datasetSummary != nil && !(datasetSummary?.isEmpty ?? true)
        guard !transcript.isEmpty || freshScreenshot != nil || !trimmedQuestion.isEmpty || !trimmedContext.isEmpty || hasDataset else { return }

        guard let provider = aiProvider else {
            errorMessage = AIProviderError.invalidAPIKey.localizedDescription
            return
        }

        isMLGuideViewVisible = true
        isMLGuideLoading = true
        mlGuideResponse = nil
        
        // Capture timestamp before starting - will be set after success
        let requestTimestamp = Date()

        mlGuideTask = Task { [weak self] in
            guard let self else { return }
            let requestID = UUID()
            
            var accumulatedResponse = ""
            
            await MainActor.run {
                self.activeMLGuideRequestID = requestID
            }
            do {
                let summary = await self.loadDatasetSummaryIfNeeded()
                let context = MLGuideContext(
                    transcript: transcript,
                    screenshots: screenshots,
                    question: questionSnapshot,
                    extraContext: extraContextSnapshot,
                    realtimePrompt: realtimePrompt,
                    previousResponse: previousResponse,
                    datasetSummary: summary
                )

                try await provider.mlGuideStreaming(context: context) { [weak self] chunk in
                    guard let self else { return }
                    accumulatedResponse += chunk
                    
                    Task { @MainActor [accumulatedResponse] in
                        guard self.session.id == sessionID,
                              self.activeMLGuideRequestID == requestID,
                              !Task.isCancelled else { return }
                        self.mlGuideResponse = accumulatedResponse
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [requestTimestamp, accumulatedResponse] in
                    guard self.session.id == sessionID,
                          self.activeMLGuideRequestID == requestID else { return }
                    let rawFinalResponse = accumulatedResponse.isEmpty
                        ? (self.mlGuideResponse ?? "")
                        : accumulatedResponse
                    let shouldApplyVoiceGuard = self.settings.shouldApplyVoiceGuard(for: providerType)
                    let voiceResult = shouldApplyVoiceGuard
                        ? self.responseVoiceGuard.normalizeText(
                            rawFinalResponse,
                            surface: .mlGuide
                        )
                        : VoiceNormalizationResult(
                            text: rawFinalResponse,
                            report: VoiceNormalizationReport(
                                coachingDetected: false,
                                firstPersonBefore: false,
                                firstPersonAfter: false,
                                rewriteCount: 0,
                                bannedOpenerRewrites: 0,
                                leadInjected: false
                            )
                        )
                    let finalResponse = voiceResult.text

                    self.isMLGuideLoading = false
                    self.mlGuideResponse = finalResponse
                    if shouldApplyVoiceGuard {
                        self.logVoiceNormalization(surface: .mlGuide, report: voiceResult.report)
                    }
                    if !finalResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastSuccessfulMLGuideResponse = finalResponse
                    }
                    // Update timestamp after EVERY ML Guide
                    self.lastMLGuideTimestamp = requestTimestamp
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.session.id == sessionID,
                          self.activeMLGuideRequestID == requestID else { return }
                    self.mlGuideResponse = nil
                    self.isMLGuideLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    /// Build transcript containing only entries AFTER the last ML Guide.
    private func buildTranscriptSinceLastMLGuide() -> String {
        guard let cutoff = lastMLGuideTimestamp else {
            // First request of session - use full transcript
            return session.transcript
        }
        
        let newEntries = session.transcriptEntries.filter { $0.timestamp > cutoff }
        
        if newEntries.isEmpty {
            if let lastEntry = session.transcriptEntries.last {
                return "\(lastEntry.speaker.displayName): \(lastEntry.text)"
            }
            return ""
        }
        
        return newEntries.map { "\($0.speaker.displayName): \($0.text)" }.joined(separator: "\n")
    }
    
    private func loadDatasetSummaryIfNeeded() async -> String? {
        let shouldLoad: Bool = await MainActor.run {
            if let datasetSummary = self.datasetSummary, !datasetSummary.isEmpty {
                return false
            }
            if self.datasetSummaryLoadAttempted {
                return false
            }
            self.datasetSummaryLoadAttempted = true
            return true
        }
        if !shouldLoad {
            return await MainActor.run { self.datasetSummary }
        }

        switch await datasetProfiler.loadDatasetSummary() {
        case .summary(let summary):
            await MainActor.run {
                self.datasetSummary = summary
            }
            NSLog("[SessionController] Dataset summary loaded successfully")
            return summary
        case .unavailable(let warning):
            await MainActor.run {
                if self.errorMessage == nil {
                    self.errorMessage = warning
                }
            }
            NSLog("[SessionController] Dataset summary unavailable: \(warning)")
            return nil
        }
    }
}
