import Foundation

struct QuickAssistExperimentRun {
    let id: String
    let sessionID: String
    let requestID: UUID
    let sourceThreadID: String
    let sourceTurnID: String
}

extension SessionController {
    func createQuickAssistExperimentFromSelectedTurn() {
        Task { @MainActor in
            await runQuickAssistExperiment()
        }
    }
    func compareQuickAssistExperiment() {
        guard let sourceThreadID = activeQuickAssistThreadID else {
            quickAssistExperimentComparison = nil
            return
        }
        let comparisonThreadID = activeQuickAssistExperiment?.candidates.first(where: \.isWinner)?.threadId ?? quickAssistExperimentThreadID
        guard let comparisonThreadID, sourceThreadID != comparisonThreadID else {
            quickAssistExperimentComparison = nil
            return
        }
        quickAssistExperimentComparison = compareQuickAssistThreads(
            leftThreadID: sourceThreadID,
            rightThreadID: comparisonThreadID
        )
    }
    func adoptQuickAssistBranch(threadID: String) {
        guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        openQuickAssistThread(threadID: threadID, showQuickAssistView: true)
        adoptExperimentWinner(threadID: threadID)
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
    }
    func clearQuickAssistExperiment() {
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
        activeQuickAssistExperiment = nil
    }
    @MainActor
    func runQuickAssistExperiment(
        providerResolver: ((AIProviderType) -> AIProvider?)? = nil
    ) async {
        guard !Task.isCancelled, let sourceThreadID = activeQuickAssistThreadID,
              let selectedTurn = selectedQuickAssistTurn ?? quickAssistTurns.last else { return }
        let sourceCalls = workstreamTimelineRepository.loadQuickAssistCalls(threadId: sourceThreadID)
        guard let baseCall = sourceCalls.last(where: { $0.turnId == selectedTurn.id.uuidString }) ?? sourceCalls.last else {
            return
        }

        let experimentID = UUID().uuidString
        let availableProviders = configuredExperimentProviders(excluding: settings.selectedProvider)
        let context = QuickAssistExperimentContext(
            baseCall: baseCall,
            selectedIntent: baseCall.routeOverrideIntent,
            routeConfidence: baseCall.routeConfidence,
            availableProviders: availableProviders,
            currentProvider: settings.selectedProvider
        )
        let plans = experimentRunner.candidatePlans(for: context)
        guard !plans.isEmpty else { return }

        beginSessionHistoryIfNeeded()
        let run = QuickAssistExperimentRun(
            id: experimentID, sessionID: session.id.uuidString,
            requestID: activeQuickAssistRequestID,
            sourceThreadID: sourceThreadID, sourceTurnID: baseCall.turnId
        )
        quickAssistExperimentThreadID = nil
        quickAssistExperimentComparison = nil
        self.logger.createQuickAssistExperiment(
            id: experimentID,
            sessionId: run.sessionID,
            sourceThreadId: sourceThreadID,
            sourceTurnId: baseCall.turnId,
            selectedIntent: baseCall.routeOverrideIntent,
            routeConfidence: baseCall.routeConfidence,
            status: .running
        )
        activeQuickAssistExperiment = logger.loadQuickAssistExperiment(id: experimentID)

        for plan in plans {
            guard isQuickAssistExperimentCurrent(run) else { return }
            _ = await createExperimentCandidateThread(
                run: run,
                baseCall: baseCall,
                plan: plan,
                sourceCalls: sourceCalls,
                providerResolver: providerResolver
            )
        }

        guard isQuickAssistExperimentCurrent(run) else { return }
        let experiment = self.logger.loadQuickAssistExperiment(id: experimentID)
        activeQuickAssistExperiment = experiment
        let winnerThreadID = experiment?.candidates.first?.threadId
        quickAssistExperimentThreadID = winnerThreadID
        if let winnerThreadID {
            quickAssistExperimentComparison = compareQuickAssistThreads(
                leftThreadID: sourceThreadID,
                rightThreadID: winnerThreadID
            )
        }
    }
    @MainActor
    func isQuickAssistExperimentCurrent(_ run: QuickAssistExperimentRun) -> Bool {
        !Task.isCancelled && session.id.uuidString == run.sessionID &&
            activeQuickAssistRequestID == run.requestID &&
            activeQuickAssistExperiment?.id == run.id &&
            logger.getSessionRecord(id: run.sessionID) != nil &&
            logger.loadQuickAssistExperiment(id: run.id) != nil &&
            logger.getQuickAssistCall(threadId: run.sourceThreadID, turnId: run.sourceTurnID) != nil
    }
    func adoptExperimentWinner(threadID: String) {
        guard let experiment = activeQuickAssistExperiment else { return }
        guard let winner = experiment.candidates.first(where: { $0.threadId == threadID }) else { return }
        self.logger.updateQuickAssistExperiment(
            id: experiment.id,
            status: .adopted,
            winnerCandidateId: winner.id
        )
        policyCalibrator.recordAcceptedWinner(candidate: winner, intent: experiment.selectedIntent)
        activeQuickAssistExperiment = self.logger.loadQuickAssistExperiment(id: experiment.id)
    }
}
