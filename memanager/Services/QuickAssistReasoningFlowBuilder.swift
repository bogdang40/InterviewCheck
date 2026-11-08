import Foundation

/// Stitches the model's per-turn text segments together with the executed tool
/// trace to produce an ordered reasoning flow. The live loop feeds thoughts in
/// arrival order so the UI can replay the journey as a single vertical thread.
final class QuickAssistReasoningFlowBuilder {
    /// One ordered fragment collected from a single assistant turn. The loop
    /// runner forwards text and tool_use blocks in the order the model emitted
    /// them, preserving the natural sequence of reasoning.
    enum Fragment: Equatable {
        case thought(text: String, iteration: Int, precedesCallID: String?)
        case toolCall(id: String, iteration: Int)
    }

    private let tracePresenter: QuickAssistToolTracePresenter

    init(tracePresenter: QuickAssistToolTracePresenter = QuickAssistToolTracePresenter()) {
        self.tracePresenter = tracePresenter
    }

    func build(
        turnID: UUID?,
        fragments: [Fragment],
        traceSteps: [QuickAssistToolTraceStep]
    ) -> QuickAssistReasoningFlow {
        let trace = QuickAssistToolTrace(turnID: turnID, steps: traceSteps)
        guard !fragments.isEmpty || !traceSteps.isEmpty else {
            return QuickAssistReasoningFlow(turnID: turnID, steps: [], trace: trace)
        }

        let stepLookup: [String: QuickAssistToolTraceStep] = Dictionary(
            uniqueKeysWithValues: traceSteps.map { ($0.id, $0) }
        )
        var renderedCallIDs = Set<String>()
        var ordered: [QuickAssistFlowStep] = []

        for fragment in fragments {
            switch fragment {
            case .thought(let text, let iteration, let precedesCallID):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let thought = QuickAssistFlowThought(
                    iteration: iteration,
                    text: trimmed,
                    precedesToolCallID: precedesCallID
                )
                ordered.append(.thought(thought))
            case .toolCall(let callID, _):
                if let step = stepLookup[callID], !renderedCallIDs.contains(callID) {
                    ordered.append(.toolCall(step))
                    renderedCallIDs.insert(callID)
                }
            }
        }

        for step in traceSteps where !renderedCallIDs.contains(step.id) {
            ordered.append(.toolCall(step))
            renderedCallIDs.insert(step.id)
        }

        return QuickAssistReasoningFlow(turnID: turnID, steps: ordered, trace: trace)
    }

    func buildFromTrace(_ trace: QuickAssistToolTrace) -> QuickAssistReasoningFlow {
        let steps = trace.steps.map(QuickAssistFlowStep.toolCall)
        return QuickAssistReasoningFlow(turnID: trace.turnID, steps: steps, trace: trace)
    }
}
