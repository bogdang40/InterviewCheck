import Foundation

extension SessionController {
    @MainActor
    func quickAssist(
        isFollowUp: Bool = false,
        mode: QuickAssistContextMode = .conversation,
        forceTier: QuickAssistModelTier? = nil,
        questionOverride: String? = nil,
        previousResponseOverride: String? = nil,
        conversationHistoryOverride: [(role: String, content: String)]? = nil,
        questionSourceOverride: QuickAssistQuestionSource? = nil
    ) {
        guard AccessGuard.allows() else {
            errorMessage = AccessGuard.deniedMessage
            return
        }
        guard !isQuickAssistLoading else { return }
        guard let provider = aiProvider else {
            errorMessage = AIProviderError.invalidAPIKey.localizedDescription
            return
        }

        quickAssistTask?.cancel()
        let requestID = UUID()
        activeQuickAssistRequestID = requestID
        let sessionID = session.id
        let threadID = ensureActiveQuickAssistThread()
        if quickAssistCoordinator.activeThreadId != threadID {
            openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        }
        let turnID = UUID().uuidString
        let effectiveQuestion = questionOverride ?? quickAssistQuestion
        let effectiveQuestionSource: QuickAssistQuestionSource = {
            if let questionSourceOverride {
                return questionSourceOverride
            }
            let trimmed = effectiveQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .none : .manual
        }()
        let selectedThreadMode = resolvedQuickAssistSelectedMode(for: threadID)
        quickAssistSelectedModeByThread[threadID] = selectedThreadMode
        quickAssistSelectedMode = selectedThreadMode
        let activeRouteOverrideIntent = selectedThreadMode.preferredIntent
        quickAssistRouteOverrideIntent = activeRouteOverrideIntent

        // Use context resolver for auto-detection unless user explicitly set a mode
        let resolver = QuickAssistContextResolver()
        let resolved = resolver.resolve(
            currentSection: currentSection,
            solveMode: solveMode,
            response: session.response,
            parsedSystemDesign: parsedSystemDesignContent,
            transcript: session.transcript,
            question: effectiveQuestion,
            extraContext: quickAssistExtraContext
        )
        let freshCaptureResult = screenshotService.captureFreshFullScreenBase64()
        let stackedScreenshots = stackedScreenshotsNewestToOldest()
        let hasVisualEvidence = freshCaptureResult.base64 != nil || !stackedScreenshots.isEmpty
        let hasTextEvidence = [effectiveQuestion, quickAssistExtraContext, session.transcript]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let route = resolveQuickAssistRequestRoute(
            threadID: threadID,
            effectiveQuestion: effectiveQuestion,
            effectiveQuestionSource: effectiveQuestionSource,
            selectedThreadMode: selectedThreadMode,
            activeRouteOverrideIntent: activeRouteOverrideIntent,
            resolved: resolved,
            hasVisualEvidence: hasVisualEvidence,
            isFollowUp: isFollowUp,
            mode: mode,
            forceTier: forceTier
        )
        let effectiveInteractionMode = route.effectiveInteractionMode
        let behaviouralStyleDecision = route.behaviouralStyleDecision
        let routingPolicyDecision = route.routingPolicyDecision
        let playbookDecision = route.playbookDecision
        let effectiveMode = route.effectiveMode
        let effectiveTier = route.effectiveTier
        let effectiveComplexity = route.effectiveComplexity
        let effectiveBudget = route.effectiveBudget
        let resolvedThreadMode = route.resolvedThreadMode
        let intentResolution = route.intentResolution
        let composition = route.composition
        let promptInteractionMode = route.promptInteractionMode

        let sectionContext: String
        if promptInteractionMode == .behavioural {
            // Spoken family answers never want solve section context bleeding
            // into a narrative response.
            sectionContext = ""
        } else if mode != .conversation {
            sectionContext = buildQuickAssistSectionContext(for: effectiveMode)
        } else {
            sectionContext = resolved.sectionContext
        }
        let retrievedRelatedMemory = settings.hubMemoryEnabled
            ? retrieveRelatedMemoryResult(
                question: effectiveQuestion,
                questionSource: effectiveQuestionSource,
                querySource: resolveRelatedMemoryQuerySource(
                    questionSource: effectiveQuestionSource,
                    isFollowUp: isFollowUp
                ),
                threadID: threadID,
                turnID: turnID,
                intent: intentResolution.intent,
                contextMode: effectiveMode,
                previousResponse: previousResponseOverride,
                sourceTurn: selectedQuickAssistTurn,
                limit: 4
            )
            : .empty
        let retrievedRelatedSnippets = retrievedRelatedMemory.snippets
        let retrievedMemorySnippets = retrievedRelatedSnippets.map(\.text)
        quickAssistRelatedMemorySnippets = retrievedRelatedSnippets
        quickAssistMemorySnippets = retrievedMemorySnippets
        quickAssistVerificationRecord = .pending
        let routeConfidence = routingPolicyDecision?.intentResolution.confidence ?? intentResolution.confidence
        let evidencePack = evidencePackBuilder.build(
            contextMode: effectiveMode,
            modelTier: effectiveTier,
            questionSource: effectiveQuestionSource,
            transcript: session.transcript,
            question: effectiveQuestion,
            extraContext: quickAssistExtraContext,
            relatedMemorySnippets: retrievedMemorySnippets,
            screenshotCount: (freshCaptureResult.base64 == nil ? 0 : 1) + stackedScreenshots.count,
            routeConfidence: routeConfidence,
            routeReason: intentResolution.reason,
            routeOverrideIntent: activeRouteOverrideIntent
        )
        let memoryContextBlock = retrievedMemorySnippets.isEmpty
            ? ""
            : """
            RELEVANT PRIOR MEMORY:
            \(retrievedMemorySnippets.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """
        // Job Workspace brief and personal knowledge graph facts ride in the
        // same extra context channel as hub memory; both are empty strings
        // when disabled or when nothing is active, so the join drops them.
        let activeJobWorkspace = WorkspaceQuickAssistBridge.shared.currentWorkspace
        let workspaceContextBlock = WorkspaceQuickAssistBridge.shared.contextBlock(question: effectiveQuestion)
        let knowledgeContextBlock = KnowledgeQuickAssistBridge.shared.contextBlock(
            question: effectiveQuestion,
            transcriptTail: String(session.transcript.suffix(600)),
            workspaceID: activeJobWorkspace?.id
        )
        let combinedExtraContext = [sectionContext, quickAssistExtraContext, memoryContextBlock, workspaceContextBlock, knowledgeContextBlock, composition.intentManifest, sessionFocusContext.promptBlock]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let resolvedRealtimePrompt = settings.resolveQuickAssistPrompt(
            transcript: session.transcript,
            question: effectiveQuestion,
            extraContext: combinedExtraContext
        )
        // Enrich with the active Mode context (prompt text, extracted attachment text, and
        // image attachments merged into stackedScreenshots). No op when no Mode is active.
        let modeContextComposition = sessionModeContextResolver.composeContext(
            for: session,
            fallbackRealtimePrompt: resolvedRealtimePrompt.text
        )
        let effectiveRealtimePromptText = modeContextComposition?.realtimePromptText
            ?? resolvedRealtimePrompt.text
        let stackedScreenshotsWithMode: [String] = {
            guard let addition = modeContextComposition?.additionalImages, !addition.isEmpty else {
                return stackedScreenshots
            }
            return stackedScreenshots + addition
        }()
        let sectionContextMessage = sectionContextWarning(for: effectiveMode, sectionContext: sectionContext)
        let captureMessage = captureFailureStatusMessage(for: freshCaptureResult)
        let baseStatusMessage = [captureMessage, sectionContextMessage, resolvedRealtimePrompt.statusMessage]
            .compactMap { $0 }
            .joined(separator: " ")
        quickAssistContextStatusMessage = baseStatusMessage.isEmpty ? nil : baseStatusMessage
        // Feature 1 (Pacing Director): apply pacing-aware contract override
        // and prepend the pacing directive to the capability addendum. Both
        // are no-ops when the director has no confident reading yet.
        let pacingAdjustedContract = PacingContractResolver.resolve(
            base: composition.outputContractOverride ?? .default,
            state: pacingState
        )
        let pacingDirective = settings.pacingDirectorEnabled
            ? PacingDirectiveFormatter.format(state: pacingState)
            : nil
        let pacingAwareAddendum: String? = {
            guard let pacingDirective else { return composition.promptAddendum }
            if let existing = composition.promptAddendum, !existing.isEmpty {
                return pacingDirective + "\n\n" + existing
            }
            return pacingDirective
        }()

        guard let preparedRequest = quickAssistCoordinator.buildRequest(
            session: session,
            question: effectiveQuestion,
            extraContext: combinedExtraContext,
            realtimePrompt: effectiveRealtimePromptText,
            interactionMode: promptInteractionMode,
            freshCaptureResult: freshCaptureResult,
            stackedScreenshotBase64: stackedScreenshotsWithMode,
            contextMode: effectiveMode,
            isFollowUp: isFollowUp,
            complexity: effectiveComplexity,
            modelTier: effectiveTier,
            tokenBudget: effectiveBudget,
            solveHistorySummary: resolved.solveHistorySummary,
            previousResponseOverride: previousResponseOverride,
            conversationHistoryOverride: conversationHistoryOverride,
            outputContractOverride: pacingAdjustedContract,
            hubIntent: intentResolution.intent,
            routeReason: intentResolution.reason,
            intentManifest: composition.intentManifest,
            routeOverrideIntent: activeRouteOverrideIntent,
            evidencePackManifest: evidencePack.manifest,
            promptAddendum: pacingAwareAddendum,
            answerPlaybookContract: composition.answerPlaybookContract,
            retrievedMemorySnippets: retrievedMemorySnippets
        ) else {
            if quickAssistContextStatusMessage == nil {
                quickAssistContextStatusMessage = sectionContextMessage
            }
            return
        }

        beginSessionHistoryIfNeeded()
        quickAssistAnswerFamilyBadge = playbookDecision.familyResolution.map {
            QuickAssistAnswerFamilyBadge(
                familyName: $0.playbook.displayName,
                frameworkName: $0.playbook.frameworkName,
                isProbe: $0.isProbe
            )
        }
        if let classifiedFamilyID = playbookDecision.familyResolution?.playbook.id,
           classifiedFamilyID != InterviewPlaybookCatalog.followUpProbe.id {
            quickAssistLastFamilyByThread[threadID] = classifiedFamilyID
        }

        let contractStatusMessage = quickAssistOutputContractStatus(
            mode: effectiveMode,
            contract: preparedRequest.context.outputContract
        )
        let tierLabel = effectiveTier == .deep ? "DEEP" : "FAST"
        let fullStatusMessage = [
            captureMessage,
            sectionContextMessage,
            resolvedRealtimePrompt.statusMessage,
            contractStatusMessage,
            quickAssistRouteSummary,
            "[\(tierLabel)]"
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        quickAssistContextStatusMessage = fullStatusMessage.isEmpty ? nil : fullStatusMessage

        self.logger.logDebugEvent(
            category: "quick_assist",
            name: "context_prepared",
            details: "freshCapture=\(preparedRequest.contextEnvelope.freshCaptureStatus.rawValue), failureReason=\(preparedRequest.contextEnvelope.freshCaptureFailureReason ?? "none"), images=\(preparedRequest.contextEnvelope.imageCount), estimatedChars=\(preparedRequest.contextEnvelope.estimatedPayloadChars), selectedMode=\(selectedThreadMode.rawValue), resolvedMode=\(resolvedThreadMode.rawValue), interactionMode=\(effectiveInteractionMode.rawValue), tier=\(effectiveTier.rawValue), complexity=\(effectiveComplexity.rawValue), budget=\(effectiveBudget.map(String.init) ?? "unbounded"), threadTurns=\(quickAssistCoordinator.thread.turnCount), intent=\(intentResolution.intent.rawValue), visualEvidence=\(hasVisualEvidence), textEvidence=\(hasTextEvidence), memory=\(retrievedMemorySnippets.count), behaviouralStyle=\(behaviouralStyleDecision?.style.rawValue ?? "n/a"), behaviouralReason=\(behaviouralStyleDecision?.exceptionReason?.rawValue ?? "none")"
        )

        if let routingPolicyDecision {
            self.logger.logQuickAssistPolicyEvent(
                QuickAssistPolicyEventRecord(
                    sessionId: sessionID.uuidString,
                    threadId: threadID,
                    turnId: turnID,
                    policyVersion: routingPolicyDecision.policyVersion,
                    selectedIntent: intentResolution.intent,
                    routeConfidence: routeConfidence,
                    routeOverride: activeRouteOverrideIntent,
                    decisionVector: routingPolicyDecision.decisionVector
                )
            )
        }

        isQuickAssistViewVisible = true
        isQuickAssistLoading = true
        quickAssistInterruptedAnswer = nil
        quickAssistRequestQuestion = effectiveQuestion
        errorMessage = nil
        rememberQuickAssistStableResponse(
            selectedQuickAssistResponseText,
            turnID: selectedQuickAssistTurn?.id
        )
        quickAssistStreamingDraft = nil

        let capturedQuestion = effectiveQuestion
        let capturedEffectiveMode = effectiveMode
        let capturedEffectiveTier = effectiveTier
        let capturedQuestionSource = effectiveQuestionSource
        let consumedComposerQuestion = questionOverride == nil && effectiveQuestionSource != .none
        let capturedIntent = intentResolution.intent
        let capturedRouteReason = intentResolution.reason
        let capturedRouteConfidence = routeConfidence
        let capturedPolicyVersion = routingPolicyDecision?.policyVersion
        let capturedRouteOverrideIntent = activeRouteOverrideIntent
        let capturedEvidencePack = evidencePack
        let capturedProviderType = settings.selectedProvider
        let capturedProviderDisplayName = capturedProviderType.displayName
        let capturedModel = effectiveTier == .deep
            ? settings.selectedModel(for: capturedProviderType)
            : settings.quickAssistModel(for: capturedProviderType)

        // Start Quick Assist call tracking with full context
        let callTracker = self.logger.startQuickAssistCall(
            sessionId: sessionID.uuidString,
            threadId: threadID,
            turnId: turnID,
            provider: capturedProviderDisplayName,
            model: capturedModel,
            isFollowUp: isFollowUp,
            transcriptText: preparedRequest.transcript,
            question: effectiveQuestion,
            extraContext: combinedExtraContext,
            hasScreenshot: preparedRequest.hasScreenshot,
            previousResponse: preparedRequest.context.previousResponse,
            contextMode: capturedEffectiveMode,
            modelTier: capturedEffectiveTier,
            questionSource: capturedQuestionSource,
            routeConfidence: capturedRouteConfidence,
            verificationStatus: .pending,
            policyVersion: capturedPolicyVersion,
            routeOverride: capturedRouteOverrideIntent,
            evidencePackManifest: capturedEvidencePack.manifest
        )

        // Detect whether the active Mode has a read only project folder enabled and this turn
        // requires tools. Project Brief always requires the read-only loop; otherwise the
        // explicit tools toggle is the source of truth.
        let toolAvailability = quickAssistToolAvailability
        let activeModeForTools = sessionModeContextResolver.resolveToolMode(for: session)
        let toolRootDescriptor = toolAvailability.rootDescriptor
        let capturedForceTools = quickAssistForceTools || capturedIntent == .projectBrief
        let shouldRouteThroughToolLoop: Bool = {
            guard capturedForceTools,
                  toolAvailability.isAvailable,
                  let mode = activeModeForTools,
                  mode.projectFolder?.isEnabled == true,
                  mode.projectFolder?.bookmarkData != nil,
                  toolRootDescriptor != nil else {
                return false
            }
            switch capturedProviderType {
            case .claude, .openai:
                return true
            case .azureOpenAI:
                return false
            }
        }()
        let capturedToolMode = activeModeForTools
        markQuickAssistFlowEventsChanged()
        quickAssistToolCallEvents = []
        quickAssistReasoningEvents = []

        executeQuickAssist(QuickAssistExecution(
            requestID: requestID,
            sessionID: sessionID,
            threadID: threadID,
            turnID: turnID,
            preparedRequest: preparedRequest,
            provider: provider,
            isFollowUp: isFollowUp,
            consumedComposerQuestion: consumedComposerQuestion,
            activeJobWorkspace: activeJobWorkspace,
            capturedQuestion: capturedQuestion,
            capturedEffectiveMode: capturedEffectiveMode,
            capturedEffectiveTier: capturedEffectiveTier,
            capturedQuestionSource: capturedQuestionSource,
            capturedIntent: capturedIntent,
            capturedRouteReason: capturedRouteReason,
            capturedEvidencePack: capturedEvidencePack,
            capturedProviderType: capturedProviderType,
            capturedModel: capturedModel,
            callTracker: callTracker,
            capturedForceTools: capturedForceTools,
            shouldRouteThroughToolLoop: shouldRouteThroughToolLoop,
            capturedToolMode: capturedToolMode,
            toolRootDescriptor: toolRootDescriptor
        ))
    }
}
