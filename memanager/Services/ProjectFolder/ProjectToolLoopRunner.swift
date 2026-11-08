import Foundation

/// Orchestrates the agentic tool calling loop: request → tool_use → execute → tool_result →
/// request again → ... → final text. Capped by the Mode's `maxToolIterations`.
final class ProjectToolLoopRunner {
    let registry: ProjectToolRegistry
    let executor: ProjectToolExecutor
    let clientFactory: ProjectToolLoopClientFactory
    let evidenceManifestBuilder: ProjectToolEvidenceManifestBuilder
    let tracePresenter: QuickAssistToolTracePresenter
    let answerReviewer: QuickAssistToolBackedAnswerReviewer
    let flowBuilder: QuickAssistReasoningFlowBuilder

    init(
        registry: ProjectToolRegistry = .shared,
        executor: ProjectToolExecutor = .shared,
        clientFactory: ProjectToolLoopClientFactory = DefaultProjectToolLoopClientFactory.shared,
        evidenceManifestBuilder: ProjectToolEvidenceManifestBuilder = ProjectToolEvidenceManifestBuilder(),
        tracePresenter: QuickAssistToolTracePresenter = QuickAssistToolTracePresenter(),
        answerReviewer: QuickAssistToolBackedAnswerReviewer = QuickAssistToolBackedAnswerReviewer(),
        flowBuilder: QuickAssistReasoningFlowBuilder = QuickAssistReasoningFlowBuilder()
    ) {
        self.registry = registry
        self.executor = executor
        self.clientFactory = clientFactory
        self.evidenceManifestBuilder = evidenceManifestBuilder
        self.tracePresenter = tracePresenter
        self.answerReviewer = answerReviewer
        self.flowBuilder = flowBuilder
    }

    func run(config: Config) async throws -> Result {
        try Task.checkCancellation()
        guard config.mode.projectFolder?.isEnabled == true,
              config.mode.projectFolder?.bookmarkData != nil else {
            throw RunError.notConfigured
        }
        let tools = registry.toolDefinitions(for: config.mode, rootDescriptor: config.rootDescriptor)
        let client = try clientFactory.makeClient(config: config, tools: tools)
        client.appendInitialUserMessage(
            text: config.userPromptText,
            imagesBase64: config.screenshotImagesBase64
        )
        if config.forceTools {
            client.appendUserTextMessage(config.promptContract.firstTurnReminder)
        }

        let maxIterations = config.mode.projectFolder?.maxToolIterations ?? 10
        var toolSummary: [String: Int] = [:]
        var iteration = 0
        var lastText = ""
        var successfulToolCalls = 0
        var hasRequestedSynthesis = false
        var hasRequestedEvidenceRepair = false
        var recordedFindings: [QuickAssistToolTraceInput] = []
        var flowFragments: [QuickAssistReasoningFlowBuilder.Fragment] = []

        while iteration < maxIterations {
            iteration += 1
            let response: ProjectToolLoopResponse
            do {
                response = try await sendIteration(client, onResponseText: config.onResponseText)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if let providerError = error as? AIProviderError, case .cancelled = providerError { throw error }
                throw RunError.underlying(error)
            }
            lastText = normalizedText(from: response)
            let iterationFragments = Self.fragments(
                from: response.orderedBlocks,
                iteration: iteration
            )
            flowFragments.append(contentsOf: iterationFragments)
            Self.emitReasoning(
                fragments: iterationFragments,
                onReasoningEvent: config.onReasoningEvent
            )

            if response.toolCalls.isEmpty {
                if shouldRecoverForcedToolTurn(
                    successfulToolCalls: successfulToolCalls,
                    forceTools: config.forceTools
                ) {
                    client.appendUserTextMessage(config.promptContract.forcedToolRecoveryReminder)
                    continue
                }
                let evidenceManifest = evidenceManifestBuilder.build(from: recordedFindings)
                if shouldRequestSynthesis(
                    responseText: lastText,
                    successfulToolCalls: successfulToolCalls,
                    hasRequestedSynthesis: hasRequestedSynthesis,
                    forceTools: config.forceTools
                ) {
                    hasRequestedSynthesis = true
                    client.appendUserTextMessage(
                        config.promptContract.synthesisReminderMessage(evidenceManifest: evidenceManifest)
                    )
                    continue
                }
                if let evidenceRepairReminder = evidenceRepairReminder(
                    responseText: lastText,
                    recordedFindings: recordedFindings,
                    hasRequestedEvidenceRepair: hasRequestedEvidenceRepair,
                    promptContract: config.promptContract,
                    evidenceManifest: evidenceManifest
                ) {
                    hasRequestedEvidenceRepair = true
                    client.appendUserTextMessage(evidenceRepairReminder)
                    continue
                }
                return Result(
                    finalText: finalizedText(
                        responseText: lastText,
                        successfulToolCalls: successfulToolCalls,
                        recordedFindings: recordedFindings,
                        rootDescriptor: config.rootDescriptor,
                        forceTools: config.forceTools
                    ),
                    iterationCount: iteration,
                    toolSummary: toolSummary,
                    reasoningFlow: buildReasoningFlow(
                        turnID: config.turnID,
                        fragments: flowFragments,
                        findings: recordedFindings
                    )
                )
            }

            let executedCalls = try await executeCallsConcurrently(
                calls: response.toolCalls,
                mode: config.mode,
                sessionID: config.sessionID?.uuidString,
                threadID: config.threadID,
                turnID: config.turnID,
                iteration: iteration,
                onToolEvent: config.onToolEvent
            )
            let results = executedCalls.map(\.result)
            for call in response.toolCalls {
                toolSummary[call.name, default: 0] += 1
            }
            successfulToolCalls += results.filter { !$0.isError }.count
            recordedFindings.append(contentsOf: executedCalls.map(\.traceInput))
            client.appendToolResults(results)
            if shouldInjectPathRecoveryReminder(results: results, forceTools: config.forceTools) {
                client.appendUserTextMessage(config.promptContract.pathRecoveryReminder)
                continue
            }
            if shouldReinforceDiscovery(results: results, iteration: iteration, forceTools: config.forceTools) {
                client.appendUserTextMessage(config.promptContract.firstTurnReminder)
            }
        }

        // Hit the cap. Ask the model to synthesize with what it has.
        if shouldRecoverForcedToolTurn(
            successfulToolCalls: successfulToolCalls,
            forceTools: config.forceTools
        ) {
            return Result(
                finalText: forcedToolFailureMessage(rootDescriptor: config.rootDescriptor),
                iterationCount: iteration,
                toolSummary: toolSummary,
                reasoningFlow: buildReasoningFlow(
                    turnID: config.turnID,
                    fragments: flowFragments,
                    findings: recordedFindings
                )
            )
        }
        let evidenceManifest = evidenceManifestBuilder.build(from: recordedFindings)
        client.appendUserTextMessage(
            "Tool iteration cap reached (\(maxIterations)). \(config.promptContract.synthesisReminderMessage(evidenceManifest: evidenceManifest))"
        )
        var synthesisText = ""
        do {
            let final = try await sendIteration(client) { text in
                synthesisText = text
                config.onResponseText?(text)
            }
            let finalFragments = Self.fragments(
                from: final.orderedBlocks,
                iteration: iteration
            )
            flowFragments.append(contentsOf: finalFragments)
            Self.emitReasoning(
                fragments: finalFragments,
                onReasoningEvent: config.onReasoningEvent
            )
            return Result(
                finalText: finalizedText(
                    responseText: normalizedText(from: final),
                    successfulToolCalls: successfulToolCalls,
                    recordedFindings: recordedFindings,
                    rootDescriptor: config.rootDescriptor,
                    forceTools: config.forceTools
                ),
                iterationCount: iteration,
                toolSummary: toolSummary,
                reasoningFlow: buildReasoningFlow(
                    turnID: config.turnID,
                    fragments: flowFragments,
                    findings: recordedFindings
                )
            )
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let providerError = error as? AIProviderError, case .cancelled = providerError { throw error }
            // A visible synthesis belongs to the interrupted turn. Returning a
            // fallback would replace it and incorrectly mark the turn complete.
            if !synthesisText.isEmpty { throw RunError.underlying(error) }
            if successfulToolCalls > 0 {
                return Result(
                    finalText: fallbackAnswer(
                        from: recordedFindings,
                        rootDescriptor: config.rootDescriptor
                    ),
                    iterationCount: iteration,
                    toolSummary: toolSummary,
                    reasoningFlow: buildReasoningFlow(
                        turnID: config.turnID,
                        fragments: flowFragments,
                        findings: recordedFindings
                    )
                )
            }
            throw RunError.loopCapped(iterations: iteration, lastText: lastText)
        }
    }

    func sendIteration(
        _ client: any ProjectToolLoopClient,
        onResponseText: ((String) -> Void)?
    ) async throws -> ProjectToolLoopResponse {
        try Task.checkCancellation()
        var text = ""
        onResponseText?(text)
        let response = try await client.send { chunk in
            guard !Task.isCancelled else { return }
            text += chunk
            onResponseText?(text)
        }
        try Task.checkCancellation()
        return response
    }

}
