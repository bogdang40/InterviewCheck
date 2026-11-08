import Foundation

extension SessionController {
    
    func runSolveSystemDesign(sessionID: UUID, requestID: UUID) async {
        let requestStart = Date()
        var didLogFirstChunk = false
        var firstChunkAt: Date?
        var didLogPartialSection = false

        self.logger.logSystemDesignEvent(
            name: "runSolveSystemDesign_start",
            details: "sessionId=\(sessionID.uuidString)"
        )
        
        let admission: (SessionContext, AIProviderType, AIProvider?, APICallTracker)? = await MainActor.run {
            guard !Task.isCancelled, self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else {
                self.logger.logSystemDesignEvent(
                    name: "runSolveSystemDesign_sessionMismatch",
                    details: "expected=\(sessionID.uuidString), current=\(self.session.id.uuidString)"
                )
                return nil
            }
            // Consolidate transcript entries before processing
            self.audioService.consolidateEntries()

            self.isLoading = true
            self.solveMode = .systemDesign
            self.errorMessage = nil
            let previousResponse = self.session.response
            let previousParsedContent = self.parsedSystemDesignContent ?? previousResponse?.parsedSystemDesign
            self.systemDesignSectionIndex = 0
            self.systemDesignStepIndexBySection = [:]
            self.systemDesignCompletenessReport = nil
            self.systemDesignRecoveryInProgress = false
            self.systemDesignStableFallbackActive = previousParsedContent?.hasContent == true

            let freshCaptureResult = self.screenshotService.captureFreshFullScreenBase64()
            self.systemDesignContextStatusMessage = self.captureFailureStatusMessage(for: freshCaptureResult)
            let orderedScreenshots = self.orderedScreenshots(
                freshCaptureResult: freshCaptureResult,
                stackedScreenshots: self.stackedScreenshotsNewestToOldest()
            )
            let contextEnvelope = self.buildContextEnvelope(
                freshCaptureResult: freshCaptureResult,
                orderedScreenshots: orderedScreenshots
            )
            
            self.logger.logSystemDesignEvent(
                name: "context_prepared",
                details: "transcriptLen=\(self.session.transcript.count), screenshots=\(contextEnvelope.imageCount), freshCapture=\(contextEnvelope.freshCaptureStatus.rawValue), failureReason=\(contextEnvelope.freshCaptureFailureReason ?? "none"), estimatedChars=\(contextEnvelope.estimatedPayloadChars)"
            )

            let context = SessionContext(
                transcript: self.session.transcript,
                screenshots: orderedScreenshots,
                previousResponse: previousResponse,
                contextEnvelope: contextEnvelope
            )
            // Admit and own the request before MainActor cancellation or
            // history deletion can run. Keep provider identity in this snapshot.
            let providerType = self.settings.selectedProvider
            let tracker = self.logger.startSystemDesignCall(
                sessionId: sessionID.uuidString,
                provider: providerType.displayName,
                model: self.settings.selectedModel(for: providerType),
                isStreaming: true
            )
            return (context, providerType, self.aiProvider, tracker)
        }

        guard let (context, providerType, admittedProvider, callTracker) = admission else { return }
        
        self.logger.logSystemDesignEvent(
            name: "api_call_start_streaming",
            details: "provider=\(providerType.displayName), model=\(settings.selectedModel(for: providerType))"
        )
        
        // Switch to system design section immediately so user sees progress
        await MainActor.run {
            guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
            self.currentSection = .systemDesign
            self.isStreaming = true
            self.streamingResponseText = ""
        }

        do {
            guard let provider = admittedProvider else {
                self.logger.logSystemDesignEvent(name: "api_call_error", details: "no provider configured")
                throw AIProviderError.invalidAPIKey
            }

            var lastCommittedSnapshot: SystemDesignProgressSnapshot? = await MainActor.run {
                guard let currentResponse = self.session.response else { return nil }
                let parsed = self.parsedSystemDesignContent ?? currentResponse.parsedSystemDesign
                return SessionController.makeSystemDesignProgressSnapshot(
                    parsed: parsed,
                    rawText: currentResponse.systemDesign
                )
            }
            var lastCommittedRawChars = lastCommittedSnapshot?.rawCharacterCount ?? 0
            var lastSkippedCommitReason: String?
            
            var accumulatedText = ""
            var lastParseTime = Date()
            let parseInterval: TimeInterval = 0.9

            let response = try await provider.completeSystemDesignStreaming(context: context) { [weak self] chunk in
                guard let self, !Task.isCancelled else { return }

                let now = Date()
                if !didLogFirstChunk {
                    didLogFirstChunk = true
                    firstChunkAt = now
                    self.logger.logSystemDesignEvent(
                        name: "first_chunk_latency_ms",
                        details: "value=\(Int(now.timeIntervalSince(requestStart) * 1000))"
                    )
                }

                accumulatedText += chunk
                
                // Update streaming text for immediate display
                let latestText = accumulatedText
                Task { @MainActor in
                    _ = self.applySystemDesignStreamText(
                        latestText, sessionID: sessionID, requestID: requestID
                    )
                }
                
                // Periodically parse and update the response for structured rendering
                if now.timeIntervalSince(lastParseTime) >= parseInterval {
                    lastParseTime = now
                    let partialResponse = MentorResponse.parse(from: accumulatedText)
                    let partialParsedSystemDesign = partialResponse.parsedSystemDesign
                    let candidateSnapshot = SessionController.makeSystemDesignProgressSnapshot(
                        parsed: partialParsedSystemDesign,
                        rawText: partialResponse.systemDesign
                    )
                    let elapsedMs = Int(now.timeIntervalSince(requestStart) * 1000)
                    let decision = SessionController.evaluateSystemDesignPartialCommit(
                        previous: lastCommittedSnapshot,
                        candidate: candidateSnapshot,
                        elapsedMs: elapsedMs,
                        charDelta: candidateSnapshot.rawCharacterCount - lastCommittedRawChars
                    )

                    if decision.shouldCommit {
                        if !didLogPartialSection && candidateSnapshot.hasStructuredContent {
                            didLogPartialSection = true
                            self.logger.logSystemDesignEvent(
                                name: "partial_section_rendered",
                                details: "elapsedMs=\(elapsedMs)"
                            )
                        }

                        self.logger.logSystemDesignEvent(
                            name: "partial_commit_applied",
                            details: "reason=\(decision.reason), sectionCount=\(candidateSnapshot.sectionCount), steps=\(candidateSnapshot.totalProgressiveStepCount), chars=\(candidateSnapshot.rawCharacterCount), elapsedMs=\(elapsedMs)"
                        )

                        lastCommittedSnapshot = candidateSnapshot
                        lastCommittedRawChars = candidateSnapshot.rawCharacterCount
                        lastSkippedCommitReason = nil

                        Task { @MainActor in
                            guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                            self.updateSessionResponse(
                                partialResponse,
                                precomputedParsedSystemDesign: partialParsedSystemDesign
                            )
                            self.systemDesignStableFallbackActive = false
                        }
                    } else if decision.reason != lastSkippedCommitReason {
                        lastSkippedCommitReason = decision.reason
                        self.logger.logSystemDesignEvent(
                            name: decision.isRegression ? "partial_commit_skipped_regression" : "partial_commit_skipped_low_signal",
                            details: "reason=\(decision.reason), sectionCount=\(candidateSnapshot.sectionCount), steps=\(candidateSnapshot.totalProgressiveStepCount), chars=\(candidateSnapshot.rawCharacterCount), elapsedMs=\(elapsedMs)"
                        )
                    }
                }
            }
            
            guard !Task.isCancelled else {
                self.logger.logSystemDesignEvent(name: "api_call_cancelled")
                callTracker.cancel()
                await MainActor.run {
                    guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                    self.isStreaming = false
                    self.isLoading = false
                    self.systemDesignStableFallbackActive = false
                }
                return
            }
            
            callTracker.complete()
            
            self.logger.logSystemDesignEvent(
                name: "api_call_complete",
                details: "responseLen=\(response.systemDesign.count)"
            )

            let finalization = await finalizeSystemDesignResponse(
                response, provider: provider, providerType: providerType,
                context: context, sessionID: sessionID, requestID: requestID
            )
            let finalResponse = finalization.response
            let completenessReport = finalization.report

            let finalParsedSystemDesign = finalResponse.parsedSystemDesign

            // Advisory cross check of the model's own COMPLETION_CHECKLIST
            // line (demanded by the prompt, previously parsed nowhere)
            // against what actually parsed.
            let declaredChecklist = SystemDesignChecklistParser.parse(finalResponse.systemDesign)
            if !declaredChecklist.isEmpty {
                let actualByTitle = Dictionary(
                    uniqueKeysWithValues: SystemDesignSectionExpectation.all.map {
                        ($0.title, finalParsedSystemDesign.progressiveStepCount(for: $0.id))
                    }
                )
                let checklistMismatches = SystemDesignChecklistParser.mismatches(
                    declared: declaredChecklist,
                    actualBySectionTitle: actualByTitle
                )
                if !checklistMismatches.isEmpty {
                    self.logger.logSystemDesignEvent(
                        name: "completion_checklist_mismatch",
                        details: checklistMismatches.joined(separator: "; ")
                    )
                }
            }

            let shouldLogPartialOnFinal = !didLogPartialSection && finalParsedSystemDesign.hasStructuredContent
            if shouldLogPartialOnFinal {
                didLogPartialSection = true
            }
            let finalizedResponse = finalResponse
            let finalizedReport = completenessReport
            let finalElapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            let transitionOrigin: String
            let transitionMs: Int
            if let firstChunkAt {
                transitionOrigin = "first_chunk"
                transitionMs = Int(Date().timeIntervalSince(firstChunkAt) * 1000)
            } else {
                transitionOrigin = "request_start"
                transitionMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            }

            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else {
                    self.logger.logSystemDesignEvent(
                        name: "response_discarded",
                        details: "session changed during API call"
                    )
                    return
                }

                if shouldLogPartialOnFinal {
                    self.logger.logSystemDesignEvent(
                        name: "partial_section_rendered",
                        details: "elapsedMs=\(finalElapsedMs), source=final_response"
                    )
                }

                self.logger.logSystemDesignEvent(
                    name: "updating_ui",
                    details: "setting final response"
                )
                
                // Set final parsed response
                self.updateSessionResponse(
                    finalizedResponse,
                    precomputedParsedSystemDesign: finalParsedSystemDesign
                )
                self.persistSolveMemory(
                    sessionID: sessionID,
                    response: finalizedResponse,
                    solveMode: .systemDesign
                )
                self.systemDesignCompletenessReport = finalizedReport
                self.systemDesignRecoveryInProgress = false
                self.systemDesignStableFallbackActive = false
                self.isStreaming = false
                self.isLoading = false
                
                self.logger.logSystemDesignEvent(
                    name: "ui_updated",
                    details: "currentSection=systemDesign, isLoading=false, isStreaming=false"
                )
                self.logger.logSystemDesignEvent(
                    name: "streaming_to_final_view_transition_ms",
                    details: "value=\(transitionMs), origin=\(transitionOrigin)"
                )
                self.logger.logSessionUpdated(session: self.session)
            }
        } catch {
            guard !Task.isCancelled else {
                callTracker.cancel()
                await MainActor.run {
                    guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                    self.systemDesignRecoveryInProgress = false
                    self.systemDesignStableFallbackActive = false
                    self.isStreaming = false
                    self.isLoading = false
                }
                return
            }
            
            self.logger.logError(
                category: "system_design",
                name: "api_call_failed",
                error: error
            )
            
            callTracker.fail(error: error)
            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                self.errorMessage = error.localizedDescription
                self.systemDesignRecoveryInProgress = false
                self.systemDesignStableFallbackActive = false
                self.isStreaming = false
                self.isLoading = false
                self.logger.logSessionUpdated(session: self.session)
            }
        }
    }
}
