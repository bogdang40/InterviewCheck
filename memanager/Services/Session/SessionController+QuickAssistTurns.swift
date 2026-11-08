import Foundation

extension SessionController {
    func syncQuickAssistTurnsFromCoordinator(selectNewest: Bool) {
        quickAssistTurns = quickAssistCoordinator.thread.turns
        guard !quickAssistTurns.isEmpty else {
            selectedQuickAssistTurnIndex = nil
            quickAssistResponse = nil
            quickAssistLastStableResponse = nil
            quickAssistLastStableTurnID = nil
            quickAssistResolvedMode = nil
            quickAssistVerificationRecord = nil
            quickAssistSelectedTurnFeedbackStatus = .none
            quickAssistRecoveryPlan = nil
            quickAssistSelectedToolTrace = nil
            quickAssistSelectedReasoningFlow = nil
            return
        }

        if selectNewest || !quickAssistTurns.indices.contains(selectedQuickAssistTurnIndex ?? -1) {
            selectedQuickAssistTurnIndex = quickAssistTurns.count - 1
        }

        if let index = selectedQuickAssistTurnIndex {
            let displayed = displayedQuickAssistResponse(for: quickAssistTurns[index])
            quickAssistResponse = displayed
            rememberQuickAssistStableResponse(
                displayed,
                turnID: quickAssistTurns[index].id
            )
        }
        syncQuickAssistSelectedTurnMetadata()
    }
    func defaultQuickAssistThreadID() -> String {
        session.id.uuidString
    }
    func bootstrapQuickAssistThreadForCurrentSession() {
        quickAssistStartsFreshThread = false
        let defaultThreadID = defaultQuickAssistThreadID()
        self.logger.createQuickAssistThread(
            threadId: defaultThreadID,
            title: nil,
            originSessionId: session.id.uuidString,
            selectedMode: .auto
        )
        pinnedMemoryNodeIDsByThread[defaultThreadID] = []
        activeQuickAssistThreadID = defaultThreadID
        quickAssistSelectedHistoryThreadID = defaultThreadID
        quickAssistCoordinator.activateThread(id: defaultThreadID, turns: [])
        quickAssistTurns = []
        selectedQuickAssistTurnIndex = nil
        quickAssistResponse = nil
        quickAssistLastStableResponse = nil
        quickAssistLastStableTurnID = nil
        quickAssistSelectedMode = .auto
        quickAssistResolvedMode = nil
        quickAssistVerificationRecord = nil
        quickAssistSelectedTurnFeedbackStatus = .none
        quickAssistRecoveryPlan = nil
        quickAssistRouteOverrideIntent = nil
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
        activeQuickAssistExperiment = nil
        quickAssistCallByTurnID = [:]
        workstreamTimelineFilter.threadId = defaultThreadID
        workstreamTimelineFilter.sessionId = session.id.uuidString
        refreshQuickAssistThreads(selectThreadID: defaultThreadID)
        refreshCoachFindings()
    }
    @discardableResult
    func ensureActiveQuickAssistThread() -> String {
        if quickAssistStartsFreshThread {
            bootstrapQuickAssistThreadForCurrentSession()
            return activeQuickAssistThreadID ?? defaultQuickAssistThreadID()
        }
        if let activeQuickAssistThreadID {
            return activeQuickAssistThreadID
        }

        refreshQuickAssistThreads()
        if let activeQuickAssistThreadID {
            return activeQuickAssistThreadID
        }

        bootstrapQuickAssistThreadForCurrentSession()
        return activeQuickAssistThreadID ?? defaultQuickAssistThreadID()
    }
    func ensureActiveQuickAssistThreadLoaded(selectNewest: Bool) {
        refreshQuickAssistThreads(selectThreadID: activeQuickAssistThreadID)
        guard let threadID = activeQuickAssistThreadID else { return }
        pinnedMemoryNodeIDsByThread[threadID] = self.logger.getQuickAssistThreadPins(threadId: threadID)
        if quickAssistCoordinator.activeThreadId == threadID {
            let calls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID)
            cacheQuickAssistCallMetadata(calls)
            let selectedMode = resolvedQuickAssistSelectedMode(for: threadID)
            quickAssistSelectedModeByThread[threadID] = selectedMode
            quickAssistSelectedMode = selectedMode
            quickAssistRouteOverrideIntent = selectedMode.preferredIntent
            syncQuickAssistTurnsFromCoordinator(selectNewest: selectNewest)
            return
        }

        let calls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID)
        cacheQuickAssistCallMetadata(calls)
        let selectedMode = resolvedQuickAssistSelectedMode(for: threadID)
        quickAssistSelectedModeByThread[threadID] = selectedMode
        quickAssistSelectedMode = selectedMode
        quickAssistRouteOverrideIntent = selectedMode.preferredIntent
        let turns = callsToThreadTurns(calls)
        quickAssistCoordinator.activateThread(id: threadID, turns: turns)
        syncQuickAssistTurnsFromCoordinator(selectNewest: selectNewest)
    }
    func callsToThreadTurns(_ calls: [QuickAssistCallRecord]) -> [QuickAssistThread.Turn] {
        calls
            .filter { $0.status == "success" }
            .filter { !($0.responseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            .map { call in
                let storedResponse = call.responseText ?? ""
                let rawResponse = call.rawResponseText ?? storedResponse
                let guardedResponse = call.guardedResponseText ?? storedResponse
                return QuickAssistThread.Turn(
                    id: UUID(uuidString: call.turnId) ?? UUID(),
                    timestamp: call.startedAt,
                    transcriptDelta: call.transcriptText ?? "",
                    question: call.question ?? "",
                    response: storedResponse,
                    provider: providerType(fromStoredValue: call.provider),
                    rawResponse: rawResponse,
                    guardedResponse: guardedResponse,
                    contextMode: call.contextMode,
                    modelTier: call.modelTier,
                    questionSource: call.questionSource
                )
            }
    }
    func quickAssistCallByTurnID(turnID: UUID) -> QuickAssistCallRecord? {
        quickAssistCallByTurnID[turnID]
    }
    func cacheQuickAssistCallMetadata(_ calls: [QuickAssistCallRecord]) {
        quickAssistCallByTurnID = Dictionary(
            uniqueKeysWithValues: calls.compactMap { call in
                guard let uuid = UUID(uuidString: call.turnId) else { return nil }
                return (uuid, call)
            }
        )
    }
    func syncQuickAssistSelectedTurnMetadata() {
        guard let selectedQuickAssistTurn else {
            quickAssistVerificationRecord = nil
            quickAssistSelectedTurnFeedbackStatus = .none
            quickAssistRecoveryPlan = nil
            quickAssistSelectedToolTrace = nil
            quickAssistSelectedReasoningFlow = nil
            return
        }
        guard let call = quickAssistCallByTurnID[selectedQuickAssistTurn.id] else {
            quickAssistVerificationRecord = nil
            quickAssistSelectedTurnFeedbackStatus = .none
            quickAssistRecoveryPlan = nil
            quickAssistSelectedToolTrace = nil
            quickAssistSelectedReasoningFlow = nil
            return
        }

        let toolRecords = workstreamTimelineRepository.loadToolCalls(turnId: call.turnId)
        let toolTrace = toolTracePresenter.present(records: toolRecords, turnID: selectedQuickAssistTurn.id)
        quickAssistSelectedToolTrace = toolTrace.isEmpty ? nil : toolTrace
        quickAssistSelectedReasoningFlow = toolTrace.isEmpty
            ? nil
            : reasoningFlowBuilder.buildFromTrace(toolTrace)

        quickAssistVerificationRecord = QuickAssistVerificationRecord(
            status: call.verificationStatus,
            confidence: call.verificationConfidence,
            unsupportedClaimCount: call.unsupportedClaimCount ?? 0,
            missingQuestions: call.verificationMissingQuestions,
            suggestedFollowUp: call.verificationSuggestedFollowUp
        )
        quickAssistSelectedTurnFeedbackStatus = call.userFeedbackStatus
        quickAssistRecoveryPlan = recoveryPlanner.buildPlan(
            input: QuickAssistRecoveryPlannerInput(
                call: call,
                relatedMemorySnippets: quickAssistRelatedMemorySnippets,
                coachFindings: activeCoachFindings
            )
        )

        quickAssistResolvedMode = resolvedThreadMode(
            for: selectedQuickAssistTurn,
            fallbackIntent: call.routeOverrideIntent
        )

        if let threadID = activeQuickAssistThreadID {
            let selectedMode = resolvedQuickAssistSelectedMode(for: threadID)
            quickAssistSelectedMode = selectedMode
            quickAssistRouteOverrideIntent = selectedMode.preferredIntent
        }
    }
    func providerType(fromStoredValue value: String) -> AIProviderType {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider = AIProviderType(rawValue: normalized) {
            return provider
        }

        switch normalized.lowercased() {
        case "openai", "openai api", "openai provider":
            return .openai
        case "azureopenai", "azure openai":
            return .azureOpenAI
        default:
            return .claude
        }
    }
    func resolvedQuestionForPersistence(
        source: QuickAssistQuestionSource,
        rawQuestion: String,
        responseText: String
    ) -> String {
        switch source {
        case .none:
            return ""
        case .manual:
            return rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        case .auto:
            if let inferred = extractInferredAutoSideQuestion(from: responseText) {
                return inferred
            }
            return "Auto side question"
        }
    }
    func extractInferredAutoSideQuestion(from responseText: String) -> String? {
        for line in responseText.components(separatedBy: .newlines).prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            let prefix = "inferred side question:"
            guard lower.hasPrefix(prefix) else { continue }
            let value = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
