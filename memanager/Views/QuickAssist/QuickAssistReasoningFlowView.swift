import SwiftUI

/// The reasoning flow above the answer: a disclosure the user can fold,
/// then alternating thought lines and tool rows so the reader sees how the
/// answer was assembled.
struct QuickAssistReasoningFlowView: View {
    let flow: QuickAssistReasoningFlow

    @State private var isExpanded = true
    @State private var expandedStepIDs: Set<String> = []

    private var isRunning: Bool {
        flow.trace.steps.contains { $0.state == .running }
    }

    private var summary: String? {
        if !flow.statusSummary.isEmpty { return flow.statusSummary }
        if flow.hasThoughts, !flow.hasToolCalls { return "narration" }
        return nil
    }

    var body: some View {
        if !flow.isEmpty {
            DisclosureCard(
                "Reasoning",
                systemImage: "sparkles",
                count: flow.toolStepCount > 0 ? flow.toolStepCount : nil,
                tone: isRunning ? .info : nil,
                isExpanded: $isExpanded,
                trailing: {
                    if let summary {
                        ToneBadge(text: summary, tone: isRunning ? .info : .neutral, monospaced: true)
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(flow.steps) { step in
                        switch step {
                        case .thought(let thought):
                            QuickAssistFlowThoughtRow(thought: thought)
                        case .toolCall(let traceStep):
                            QuickAssistFlowToolRow(
                                step: traceStep,
                                isExpanded: expandedStepIDs.contains(traceStep.id),
                                onToggleExpanded: { toggleExpanded(traceStep.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(DesignTokens.Motion.sectionExpand) {
            if expandedStepIDs.contains(id) {
                expandedStepIDs.remove(id)
            } else {
                expandedStepIDs.insert(id)
            }
        }
    }
}
