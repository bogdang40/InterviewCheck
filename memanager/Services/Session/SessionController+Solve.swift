import Foundation

extension SessionController {
    func runSolve(sessionID: UUID, requestID: UUID) async {
        let admission: (SessionContext, AIProviderType, AIProvider?, APICallTracker)? = await MainActor.run {
            guard !Task.isCancelled, self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return nil }
            // Consolidate transcript entries before processing
            self.audioService.consolidateEntries()

            self.isLoading = true
            self.isStreaming = true
            self.streamingResponseText = ""
            self.currentSection = .problem
            self.errorMessage = nil
            self.systemDesignRecoveryInProgress = false
            self.systemDesignCompletenessReport = nil
            self.systemDesignStableFallbackActive = false
            // Feature 2: reset canvas parser and scene for a fresh solve.
            self.canvasParser.reset()
            self.canvasDirector.reset()

            let context = SessionContext(
                transcript: self.session.transcript,
                screenshots: self.screenshotService.getBase64Images(),
                previousResponse: self.session.response
            )
            // Admit and own the request before MainActor cancellation or
            // history deletion can run. Keep provider identity in this snapshot.
            let providerType = self.settings.selectedProvider
            let tracker = self.logger.startSolveCall(
                sessionId: sessionID.uuidString,
                provider: providerType.displayName,
                model: self.settings.selectedModel(for: providerType),
                isStreaming: true
            )
            return (context, providerType, self.aiProvider, tracker)
        }

        guard let (context, providerType, admittedProvider, callTracker) = admission else { return }

        do {
            guard let provider = admittedProvider else {
                throw AIProviderError.invalidAPIKey
            }

            // Use streaming for progressive display - user sees content immediately.
            // Feature 2 (Live Reasoning Canvas): each chunk goes through the
            // StreamingCanvasParser which peels `canvas:*` fenced blocks out
            // of the prose and forwards them as commands to the director.
            // The resulting prose is what the rendered response sees.
            let response = try await provider.completeStreaming(context: context) { [weak self] chunk in
                guard let self, !Task.isCancelled else { return }
                Task { @MainActor in
                    _ = self.applySolveStreamChunk(chunk, sessionID: sessionID, requestID: requestID)
                }
            }
            guard !Task.isCancelled else {
                callTracker.cancel()
                return
            }
            
            // Log successful completion with full response payload
            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                callTracker.complete(responsePayload: self.streamingResponseText)
            }

            let shouldApplyVoiceGuard = self.settings.shouldApplyVoiceGuard(for: providerType)
            let normalized = shouldApplyVoiceGuard
                ? self.responseVoiceGuard.normalizeMentorResponse(
                    response,
                    systemDesignMode: false
                )
                : (
                    response: response,
                    report: VoiceNormalizationReport(
                        coachingDetected: false,
                        firstPersonBefore: false,
                        firstPersonAfter: false,
                        rewriteCount: 0,
                        bannedOpenerRewrites: 0,
                        leadInjected: false
                    )
                )

            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                if shouldApplyVoiceGuard {
                    self.logVoiceNormalization(surface: .solve, report: normalized.report)
                }
                self.updateSessionResponse(normalized.response)
                self.persistSolveMemory(
                    sessionID: sessionID,
                    response: normalized.response,
                    solveMode: .algorithm
                )
                self.isLoading = false
                self.isStreaming = false
                self.streamingResponseText = ""
                self.logger.logSessionUpdated(session: self.session)
            }
        } catch {
            guard !Task.isCancelled else {
                callTracker.cancel()
                return
            }
            callTracker.fail(error: error)
            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isStreaming = false
                self.logger.logSessionUpdated(session: self.session)
            }
        }
    }
}
