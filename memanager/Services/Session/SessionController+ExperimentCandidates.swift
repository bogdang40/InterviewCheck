import Foundation

extension SessionController {
    @discardableResult
    func branchQuickAssistThread(fromThreadID: String, turnID: String) -> String? {
        if isQuickAssistLoading {
            cancelActiveRequest()
        }

        let sourceCalls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: fromThreadID)
            .filter { $0.status == "success" }
        guard !sourceCalls.isEmpty else { return nil }

        beginSessionHistoryIfNeeded()
        let sessionID = session.id.uuidString
        let branchIndex = sourceCalls.firstIndex(where: { $0.turnId == turnID }) ?? (sourceCalls.count - 1)
        let callsToCopy = Array(sourceCalls.prefix(branchIndex + 1))
        let newThreadID = UUID().uuidString
        let branchTitle = "Branch • \(callsToCopy.last?.question ?? "Quick Assist")"
        let sourceMode = resolvedQuickAssistSelectedMode(for: fromThreadID)

        self.logger.createQuickAssistThread(
            threadId: newThreadID,
            title: String(branchTitle.prefix(80)),
            originSessionId: sessionID,
            parentThreadId: fromThreadID,
            branchedFromTurnId: turnID,
            selectedMode: sourceMode
        )

        for (index, call) in callsToCopy.enumerated() {
            let startedAt = Date().addingTimeInterval(Double(index) * 0.01)
            let copied = call.copiedInto(
                sessionId: sessionID,
                threadId: newThreadID,
                startedAt: startedAt,
                modelTier: call.modelTier,
                experimentGroupId: call.experimentGroupId,
                candidateLabel: call.candidateLabel,
                baseTurnId: call.baseTurnId,
                candidateRole: call.candidateRole
            )
            self.logger.logQuickAssistCall(copied)
        }

        refreshQuickAssistThreads(selectThreadID: newThreadID)
        openQuickAssistThread(threadID: newThreadID, showQuickAssistView: true)
        workstreamCompareLeftThreadID = fromThreadID
        workstreamCompareRightThreadID = newThreadID
        refreshWorkstreamTimeline()
        refreshCoachFindings()
        return newThreadID
    }
    func configuredExperimentProviders(excluding current: AIProviderType) -> [AIProviderType] {
        AIProviderType.allCases.filter { providerType in
            guard providerType != current else { return false }
            switch providerType {
            case .azureOpenAI:
                let config = settings.azureOpenAIConfig()
                return !settings.apiKey(for: providerType).isEmpty &&
                    !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !config.deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .claude, .openai:
                return !settings.apiKey(for: providerType).isEmpty
            }
        }
    }
    @MainActor
    func createExperimentCandidateThread(
        run: QuickAssistExperimentRun,
        baseCall: QuickAssistCallRecord,
        plan: QuickAssistExperimentCandidatePlan,
        sourceCalls: [QuickAssistCallRecord],
        providerResolver: ((AIProviderType) -> AIProvider?)?
    ) async -> String? {
        guard isQuickAssistExperimentCurrent(run) else { return nil }
        guard let branchThreadID = copyThreadSliceForExperiment(
            fromThreadID: run.sourceThreadID,
            turnID: baseCall.turnId,
            experimentID: run.id,
            sessionID: run.sessionID,
            plan: plan,
            sourceCalls: sourceCalls
        ) else {
            return nil
        }

        if plan.role == .currentRoute {
            return branchThreadID
        }

        let resolvedProvider = providerResolver.map { $0(plan.providerType) } ?? provider(for: plan.providerType)
        guard let provider = resolvedProvider else {
            return nil
        }
        let history = conversationHistoryForCall(baseCall, in: sourceCalls)
        let tracker = self.logger.startQuickAssistCall(
            sessionId: run.sessionID,
            threadId: branchThreadID,
            turnId: UUID().uuidString,
            provider: plan.providerType.displayName,
            model: plan.modelTier == .deep ? settings.selectedModel(for: plan.providerType) : settings.quickAssistModel(for: plan.providerType),
            isFollowUp: false,
            transcriptText: baseCall.transcriptText ?? "",
            question: baseCall.question ?? "",
            extraContext: baseCall.extraContext ?? "",
            hasScreenshot: false,
            previousResponse: baseCall.previousResponse,
            contextMode: baseCall.contextMode,
            modelTier: plan.modelTier,
            questionSource: baseCall.questionSource,
            routeConfidence: baseCall.routeConfidence,
            verificationStatus: .pending,
            policyVersion: baseCall.policyVersion,
            routeOverride: baseCall.routeOverrideIntent,
            evidencePackManifest: baseCall.evidencePackManifest,
            experimentGroupId: run.id,
            candidateLabel: plan.label,
            baseTurnId: baseCall.turnId,
            candidateRole: plan.role
        )

        let context = QuickAssistContext(
            transcript: baseCall.transcriptText ?? "",
            screenshots: [],
            question: baseCall.question ?? "",
            extraContext: baseCall.extraContext ?? "",
            realtimePrompt: "",
            interactionMode: resolvedQuickAssistSelectedMode(for: branchThreadID).interactionMode,
            previousResponse: baseCall.previousResponse,
            contextMode: baseCall.contextMode,
            outputContract: .default,
            contextEnvelope: nil,
            conversationHistory: history,
            complexity: .moderate,
            modelTier: plan.modelTier,
            tokenBudget: nil,
            solveHistorySummary: nil,
            hubIntent: baseCall.routeOverrideIntent ?? .conversation,
            routeReason: "experiment",
            intentManifest: nil,
            routeOverrideIntent: baseCall.routeOverrideIntent,
            evidencePackManifest: baseCall.evidencePackManifest,
            capabilityPromptAddendum: nil,
            retrievedMemorySnippets: []
        )

        do {
            let response = try await provider.quickAssist(context: context)
            guard isQuickAssistExperimentCurrent(run),
                  !logger.getQuickAssistCallsForThread(threadId: branchThreadID, limit: 1).isEmpty else {
                // Ownership suppresses this audit if the branch or session was deleted.
                tracker.cancel()
                return nil
            }
            tracker.complete(responseText: response, rawResponseText: response, guardedResponseText: response, resolvedQuestion: baseCall.question)
            let verification = answerVerifier.verify(
                responseText: response,
                question: baseCall.question ?? "",
                evidencePack: evidencePackBuilder.build(
                    contextMode: baseCall.contextMode,
                    modelTier: plan.modelTier,
                    questionSource: baseCall.questionSource,
                    transcript: baseCall.transcriptText ?? "",
                    question: baseCall.question ?? "",
                    extraContext: baseCall.extraContext ?? "",
                    relatedMemorySnippets: [],
                    screenshotCount: 0,
                    routeConfidence: baseCall.routeConfidence ?? 0.5,
                    routeReason: "experiment",
                    routeOverrideIntent: baseCall.routeOverrideIntent
                )
            )
            self.logger.updateQuickAssistCallVerification(
                threadId: branchThreadID,
                turnId: tracker.lastRecordedTurnId ?? "",
                verification: verification
            )
        } catch {
            guard isQuickAssistExperimentCurrent(run),
                  !logger.getQuickAssistCallsForThread(threadId: branchThreadID, limit: 1).isEmpty else {
                tracker.cancel()
                return nil
            }
            tracker.fail(error: error)
        }

        refreshQuickAssistThreads(selectThreadID: activeQuickAssistThreadID)
        if let experiment = self.logger.loadQuickAssistExperiment(id: run.id),
           let winner = experiment.candidates.max(by: { lhs, rhs in
               if lhs.score.total == rhs.score.total {
                   let lhsLatency = lhs.latencyMs ?? Int.max
                   let rhsLatency = rhs.latencyMs ?? Int.max
                   if lhsLatency == rhsLatency {
                       return lhs.provider > rhs.provider
                   }
                   return lhsLatency > rhsLatency
               }
               return lhs.score.total < rhs.score.total
           }) {
            self.logger.updateQuickAssistExperiment(id: run.id, status: .completed, winnerCandidateId: winner.id)
        }
        return branchThreadID
    }
    @MainActor
    private func copyThreadSliceForExperiment(
        fromThreadID: String,
        turnID: String,
        experimentID: String,
        sessionID: String,
        plan: QuickAssistExperimentCandidatePlan,
        sourceCalls: [QuickAssistCallRecord]
    ) -> String? {
        let successfulCalls = sourceCalls.filter { $0.status == "success" }
        guard !successfulCalls.isEmpty else { return nil }
        let branchIndex = successfulCalls.firstIndex(where: { $0.turnId == turnID }) ?? (successfulCalls.count - 1)
        let callsToCopy = Array(successfulCalls.prefix(branchIndex + 1))
        let newThreadID = UUID().uuidString
        let sourceMode = resolvedQuickAssistSelectedMode(for: fromThreadID)

        self.logger.createQuickAssistThread(
            threadId: newThreadID,
            title: "Experiment • \(plan.label)",
            originSessionId: sessionID,
            parentThreadId: fromThreadID,
            branchedFromTurnId: turnID,
            selectedMode: sourceMode
        )

        for (index, call) in callsToCopy.enumerated() {
            let startedAt = Date().addingTimeInterval(Double(index) * 0.01)
            let isCandidateTurn = index == callsToCopy.count - 1
            let copied = call.copiedInto(
                sessionId: sessionID,
                threadId: newThreadID,
                startedAt: startedAt,
                modelTier: isCandidateTurn ? plan.modelTier : call.modelTier,
                experimentGroupId: isCandidateTurn ? experimentID : nil,
                candidateLabel: isCandidateTurn ? plan.label : nil,
                baseTurnId: isCandidateTurn ? turnID : nil,
                candidateRole: isCandidateTurn ? plan.role : nil
            )
            self.logger.logQuickAssistCall(copied)
        }

        return newThreadID
    }
    private func conversationHistoryForCall(
        _ baseCall: QuickAssistCallRecord,
        in sourceCalls: [QuickAssistCallRecord]
    ) -> [(role: String, content: String)] {
        let successfulCalls = sourceCalls.filter { $0.status == "success" }
        guard let index = successfulCalls.firstIndex(where: { $0.turnId == baseCall.turnId }) else {
            return []
        }
        return Array(successfulCalls.prefix(index).suffix(3)).flatMap { call in
            [
                (role: "user", content: call.question ?? ""),
                (role: "assistant", content: call.responseText ?? "")
            ]
        }
    }
}
