import Foundation

extension ProjectToolLoopRunner {
    func shouldInjectPathRecoveryReminder(results: [ToolResult], forceTools: Bool) -> Bool {
        guard forceTools else { return false }
        return results.contains { result in
            guard result.isError else { return false }
            return result.content.contains("selected_root:")
                || result.content.contains("Absolute paths are not allowed")
                || result.content.contains("outside the selected project root")
                || result.content.contains("Parent traversal is not allowed")
        }
    }

    func shouldReinforceDiscovery(results: [ToolResult], iteration: Int, forceTools: Bool) -> Bool {
        guard forceTools, iteration == 1 else { return false }
        return results.allSatisfy(\.isError)
    }

    func shouldRecoverForcedToolTurn(
        successfulToolCalls: Int,
        forceTools: Bool
    ) -> Bool {
        forceTools && successfulToolCalls == 0
    }

    func shouldRequestSynthesis(
        responseText: String,
        successfulToolCalls: Int,
        hasRequestedSynthesis: Bool,
        forceTools: Bool
    ) -> Bool {
        if successfulToolCalls == 0 { return false }
        if hasRequestedSynthesis { return false }
        if forceTools { return true }
        return responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalizedText(from response: ProjectToolLoopResponse) -> String {
        response.textSegments
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finalizedText(
        responseText: String,
        successfulToolCalls: Int,
        recordedFindings: [QuickAssistToolTraceInput],
        rootDescriptor: ProjectToolRootDescriptor,
        forceTools: Bool
    ) -> String {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if successfulToolCalls > 0 {
            return fallbackAnswer(from: recordedFindings, rootDescriptor: rootDescriptor)
        }
        if forceTools {
            return forcedToolFailureMessage(rootDescriptor: rootDescriptor)
        }
        return trimmed
    }

    func fallbackAnswer(
        from recordedFindings: [QuickAssistToolTraceInput],
        rootDescriptor: ProjectToolRootDescriptor
    ) -> String {
        let successfulFindings = recordedFindings.filter { $0.state == .completed }
        guard !successfulFindings.isEmpty else {
            return forcedToolFailureMessage(rootDescriptor: rootDescriptor)
        }
        let manifest = evidenceManifestBuilder.build(from: Array(successfulFindings.prefix(3)))
        return """
        I gathered project tool findings from \(rootDescriptor.displayPath), but the provider returned no final answer text. Confirmed findings:
        \(manifest)
        """
    }

    func evidenceRepairReminder(
        responseText: String,
        recordedFindings: [QuickAssistToolTraceInput],
        hasRequestedEvidenceRepair: Bool,
        promptContract: ProjectToolPromptContract,
        evidenceManifest: String
    ) -> String? {
        guard !hasRequestedEvidenceRepair else { return nil }
        let trace = tracePresenter.present(inputs: recordedFindings, turnID: nil)
        let review = answerReviewer.review(responseText: responseText, trace: trace)
        guard review.needsRevision else { return nil }
        return promptContract.evidenceRepairReminder(
            reason: review.reason ?? "",
            evidenceManifest: evidenceManifest
        )
    }

    func forcedToolFailureMessage(rootDescriptor: ProjectToolRootDescriptor) -> String {
        """
        I could not gather valid project findings from the selected root \(rootDescriptor.displayPath) because forced tool use never produced a successful in root read or discovery call. Retry this turn with the same root, or switch to Claude or OpenAI if the current provider is not cooperating with the tool loop.
        """
    }

    static func emitReasoning(
        fragments: [QuickAssistReasoningFlowBuilder.Fragment],
        onReasoningEvent: (@Sendable (ProjectToolReasoningEvent) -> Void)?
    ) {
        guard let onReasoningEvent else { return }
        for fragment in fragments {
            guard case .thought(let text, let iteration, let precedesCallID) = fragment else { continue }
            onReasoningEvent(ProjectToolReasoningEvent(
                iteration: iteration,
                text: text,
                precedesCallID: precedesCallID
            ))
        }
    }

    static func fragments(
        from blocks: [ProjectToolLoopContentBlock],
        iteration: Int
    ) -> [QuickAssistReasoningFlowBuilder.Fragment] {
        var fragments: [QuickAssistReasoningFlowBuilder.Fragment] = []
        var pendingThoughtIndex: Int?
        for block in blocks {
            switch block {
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                fragments.append(.thought(text: trimmed, iteration: iteration, precedesCallID: nil))
                pendingThoughtIndex = fragments.count - 1
            case .toolCall(let call):
                if let index = pendingThoughtIndex,
                   case .thought(let text, let iter, _) = fragments[index] {
                    fragments[index] = .thought(text: text, iteration: iter, precedesCallID: call.id)
                }
                fragments.append(.toolCall(id: call.id, iteration: iteration))
                pendingThoughtIndex = nil
            }
        }
        return fragments
    }

    func buildReasoningFlow(
        turnID: String?,
        fragments: [QuickAssistReasoningFlowBuilder.Fragment],
        findings: [QuickAssistToolTraceInput]
    ) -> QuickAssistReasoningFlow {
        let trace = tracePresenter.present(inputs: findings, turnID: nil)
        let resolvedTurnID = turnID.flatMap(UUID.init(uuidString:))
        return flowBuilder.build(
            turnID: resolvedTurnID,
            fragments: fragments,
            traceSteps: trace.steps
        )
    }
}
