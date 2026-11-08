import Foundation

struct QuickAssistExecution {
    let requestID: UUID
    let sessionID: UUID
    let threadID: String
    let turnID: String
    let preparedRequest: QuickAssistPreparedRequest
    let provider: AIProvider
    let isFollowUp: Bool
    let consumedComposerQuestion: Bool
    let activeJobWorkspace: JobWorkspace?
    let capturedQuestion: String
    let capturedEffectiveMode: QuickAssistContextMode
    let capturedEffectiveTier: QuickAssistModelTier
    let capturedQuestionSource: QuickAssistQuestionSource
    let capturedIntent: QuickAssistIntent
    let capturedRouteReason: String
    let capturedEvidencePack: QuickAssistEvidencePack
    let capturedProviderType: AIProviderType
    let capturedModel: String
    let callTracker: QuickAssistCallTracker
    let capturedForceTools: Bool
    let shouldRouteThroughToolLoop: Bool
    let capturedToolMode: Mode?
    let toolRootDescriptor: ProjectToolRootDescriptor?
}

extension SessionController {
    @MainActor
    func executeQuickAssist(_ execution: QuickAssistExecution) {
        let requestID = execution.requestID
        let sessionID = execution.sessionID
        let threadID = execution.threadID
        let turnID = execution.turnID
        let preparedRequest = execution.preparedRequest
        let provider = execution.provider
        let isFollowUp = execution.isFollowUp
        let consumedComposerQuestion = execution.consumedComposerQuestion
        let activeJobWorkspace = execution.activeJobWorkspace
        let capturedQuestion = execution.capturedQuestion
        let capturedEffectiveMode = execution.capturedEffectiveMode
        let capturedEffectiveTier = execution.capturedEffectiveTier
        let capturedQuestionSource = execution.capturedQuestionSource
        let capturedIntent = execution.capturedIntent
        let capturedRouteReason = execution.capturedRouteReason
        let capturedEvidencePack = execution.capturedEvidencePack
        let capturedProviderType = execution.capturedProviderType
        let capturedModel = execution.capturedModel
        let callTracker = execution.callTracker
        let capturedForceTools = execution.capturedForceTools
        let shouldRouteThroughToolLoop = execution.shouldRouteThroughToolLoop
        let capturedToolMode = execution.capturedToolMode
        let toolRootDescriptor = execution.toolRootDescriptor
        quickAssistTask = Task { [weak self, requestID] in
            guard let self else { return }

            // Track accumulated response for efficient single-update pattern
            var accumulatedResponse = ""

            do {
                if shouldRouteThroughToolLoop, let toolMode = capturedToolMode, let toolRootDescriptor {
                    let inputs = ProjectToolLoopInputs.derive(
                        from: preparedRequest.context,
                        rootDescriptor: toolRootDescriptor
                    )
                    let runner = ProjectToolLoopRunner()
                    let config = ProjectToolLoopRunner.Config(
                        providerType: capturedProviderType,
                        mode: toolMode,
                        model: capturedModel,
                        apiKey: self.settings.apiKey(for: capturedProviderType),
                        systemPrompt: inputs.systemPrompt,
                        userPromptText: inputs.userPromptText,
                        screenshotImagesBase64: inputs.imagesBase64,
                        rootDescriptor: inputs.rootDescriptor,
                        promptContract: inputs.promptContract,
                        sessionID: sessionID,
                        threadID: threadID,
                        turnID: turnID,
                        forceTools: capturedForceTools,
                        onToolEvent: { event in
                            Task { @MainActor in
                                guard self.session.id == sessionID,
                                      self.activeQuickAssistRequestID == requestID,
                                      self.isQuickAssistLoading else { return }
                                self.appendToolCallEvent(event)
                            }
                        },
                        onReasoningEvent: { event in
                            Task { @MainActor in
                                guard self.session.id == sessionID,
                                      self.activeQuickAssistRequestID == requestID,
                                      self.isQuickAssistLoading else { return }
                                self.appendReasoningEvent(event)
                            }
                        },
                        onResponseText: { text in
                            guard !Task.isCancelled else { return }
                            accumulatedResponse = text
                            DispatchQueue.main.async {
                                _ = self.applyQuickAssistStreamUpdate(
                                    text, sessionID: sessionID, requestID: requestID
                                )
                            }
                        }
                    )
                    let loopResult = try await runner.run(config: config)
                    accumulatedResponse = loopResult.finalText
                    let summary = loopResult.toolSummary
                        .map { "\($0.key)x\($0.value)" }
                        .sorted()
                        .joined(separator: ", ")
                    self.logger.logDebugEvent(
                        category: "project_tool_loop",
                        name: "completed",
                        details: "iterations=\(loopResult.iterationCount), tools=\(summary.isEmpty ? "none" : summary)"
                    )
                    DispatchQueue.main.async {
                        _ = self.applyQuickAssistStreamUpdate(
                            accumulatedResponse,
                            sessionID: sessionID,
                            requestID: requestID
                        )
                    }
                } else {
                // Use streaming with batched chunks (16ms batching from AI provider)
                // Each callback is already batched, so we can update directly
                try await provider.quickAssistStreaming(context: preparedRequest.context) { [weak self] chunk in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    accumulatedResponse += chunk

                    let latestResponse = accumulatedResponse
                    DispatchQueue.main.async {
                        _ = self.applyQuickAssistStreamUpdate(
                            latestResponse,
                            sessionID: sessionID,
                            requestID: requestID
                        )
                    }
                }
                }
                guard !Task.isCancelled else {
                    callTracker.cancel()
                    return
                }
                await MainActor.run {
                    guard self.session.id == sessionID,
                          self.activeQuickAssistRequestID == requestID else { return }
                    self.logger.logDebugEvent(
                        category: "openai_stream",
                        name: "responses_stream_started",
                        details: "provider=\(capturedProviderType.rawValue), model=\(capturedProviderType == .openai ? preparedRequest.context.modelTier.rawValue : "n/a")"
                    )
                }
                await MainActor.run { [preparedRequest, accumulatedResponse] in
                    guard self.session.id == sessionID,
                          self.activeQuickAssistRequestID == requestID else { return }
                    let rawFinalResponse = accumulatedResponse.isEmpty
                        ? (self.quickAssistStreamingDraft ?? "")
                        : accumulatedResponse
                    let guardedResult = self.responseVoiceGuard.normalizeText(
                        rawFinalResponse,
                        surface: .quickAssist
                    )
                    let guardedResponse = guardedResult.text
                    let shouldApplyVoiceGuard = self.settings.shouldApplyVoiceGuard(for: capturedProviderType)
                    let finalResponse = shouldApplyVoiceGuard ? guardedResponse : rawFinalResponse
                    let displayResponse = self.displayedQuickAssistResponse(
                        provider: capturedProviderType,
                        rawResponse: rawFinalResponse,
                        guardedResponse: guardedResponse,
                        appliedResponse: finalResponse
                    )
                    let displaySource = self.quickAssistResponseSourceLabel(for: capturedProviderType)
                    let rawEqualsGuarded = rawFinalResponse == guardedResponse
                    let resolvedQuestion = self.resolvedQuestionForPersistence(
                        source: capturedQuestionSource,
                        rawQuestion: capturedQuestion,
                        responseText: finalResponse
                    )
                    self.isQuickAssistLoading = false
                    self.quickAssistStreamingDraft = nil
                    self.quickAssistResponse = displayResponse
                    self.rememberQuickAssistStableResponse(
                        displayResponse,
                        turnID: UUID(uuidString: turnID)
                    )
                    self.logger.logDebugEvent(
                        category: "quick_assist",
                        name: "output_source_selected",
                        details: "provider=\(capturedProviderType.rawValue), guardEnabled=\(shouldApplyVoiceGuard), displayMode=\(self.settings.openAIQuickAssistDisplayMode.rawValue), source=\(displaySource), rawEqualsGuarded=\(rawEqualsGuarded)"
                    )
                    if capturedProviderType != .openai || shouldApplyVoiceGuard {
                        self.logVoiceNormalization(surface: .quickAssist, report: guardedResult.report)
                    }
                    // Log successful completion with full response text
                    callTracker.complete(
                        responseText: finalResponse,
                        rawResponseText: rawFinalResponse,
                        guardedResponseText: guardedResponse,
                        resolvedQuestion: resolvedQuestion
                    )
                    self.runQuickAssistVerification(
                        threadID: threadID,
                        turnID: turnID,
                        question: resolvedQuestion,
                        responseText: finalResponse,
                        evidencePack: capturedEvidencePack
                    )
                    self.quickAssistCoordinator.markSuccessfulResponse(
                        finalResponse,
                        rawResponse: rawFinalResponse,
                        guardedResponse: guardedResponse,
                        provider: capturedProviderType,
                        requestTimestamp: preparedRequest.requestTimestamp,
                        turnId: turnID,
                        transcript: preparedRequest.transcript,
                        question: resolvedQuestion,
                        contextMode: capturedEffectiveMode,
                        modelTier: capturedEffectiveTier,
                        questionSource: capturedQuestionSource
                    )
                    self.persistQuickAssistMemory(
                        sessionID: sessionID,
                        threadID: threadID,
                        turnID: turnID,
                        question: resolvedQuestion,
                        response: finalResponse,
                        intent: capturedIntent,
                        mode: capturedEffectiveMode,
                        tier: capturedEffectiveTier,
                        questionSource: capturedQuestionSource,
                        isFollowUp: isFollowUp,
                        routeReason: capturedRouteReason
                    )
                    WorkspaceQuickAssistBridge.shared.recordProblemSolved(
                        workspaceID: activeJobWorkspace?.id,
                        question: resolvedQuestion,
                        response: finalResponse,
                        sessionID: sessionID.uuidString,
                        threadID: threadID,
                        turnID: turnID
                    )
                    KnowledgeQuickAssistBridge.shared.ingestTurn(
                        question: resolvedQuestion,
                        response: finalResponse,
                        sourceRef: "\(threadID):\(turnID)",
                        workspace: activeJobWorkspace
                    )
                    self.syncQuickAssistTurnsFromCoordinator(selectNewest: true)
                    self.refreshQuickAssistThreads(selectThreadID: threadID)
                    let updatedCalls = self.workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID)
                    self.cacheQuickAssistCallMetadata(updatedCalls)
                    self.syncQuickAssistSelectedTurnMetadata()
                    self.refreshQuickAssistRelatedMemoryContext(trigger: .turnSelection)
                    self.refreshCoachFindings()
                    self.evaluateProactiveFailureCoach(force: true)
                    if consumedComposerQuestion {
                        self.quickAssistQuestion = ""
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    callTracker.cancel()
                    return
                }
                callTracker.fail(error: error)
                await MainActor.run {
                    guard self.session.id == sessionID,
                          self.activeQuickAssistRequestID == requestID else { return }
                    // A failure can settle before a queued main-thread draft update.
                    // Preserve the provider's latest text even in that ordering.
                    let interruptedText = accumulatedResponse.isEmpty
                        ? (self.quickAssistStreamingDraft ?? "") : accumulatedResponse
                    if !interruptedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.quickAssistInterruptedAnswer = QuickAssistInterruptedAnswer(
                            response: interruptedText, question: capturedQuestion, reason: .failed
                        )
                    }
                    self.isQuickAssistLoading = false
                    self.quickAssistStreamingDraft = nil
                    self.quickAssistResponse = self.selectedQuickAssistResponseText
                    self.rememberQuickAssistStableResponse(
                        self.quickAssistResponse,
                        turnID: self.selectedQuickAssistTurn?.id
                    )
                    self.quickAssistVerificationRecord = QuickAssistVerificationRecord(
                        status: .failed,
                        confidence: nil,
                        unsupportedClaimCount: 0,
                        missingQuestions: [error.localizedDescription],
                        suggestedFollowUp: "Retry this turn with clarified context."
                    )
                    self.errorMessage = error.localizedDescription
                    self.evaluateProactiveFailureCoach(force: true)
                }
            }
        }
    }
}
