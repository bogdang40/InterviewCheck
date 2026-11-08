import SwiftUI

/// Advanced thread tooling behind one disclosure: the active thread and
/// its timeline, live response cards, and branch experiments.
struct QuickAssistThreadToolsCard: View {
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    @Binding var isExpanded: Bool

    private var hasExperiment: Bool {
        guard let experimentThreadID = state.experimentThreadID else { return false }
        return !experimentThreadID.isEmpty
    }

    var body: some View {
        DisclosureCard(
            "Thread tools",
            systemImage: "wrench.and.screwdriver",
            tone: hasExperiment || state.liveResponseCard != nil ? .info : nil,
            isExpanded: $isExpanded,
            trailing: {
                if hasExperiment {
                    ToneBadge(text: "Experiment", tone: .info)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                threadRow
                if let card = state.liveResponseCard {
                    Hairline()
                    QuickAssistLiveResponseCardRow(
                        card: card,
                        cardCount: state.liveResponseCardCount,
                        onCycle: actions.onCycleLiveResponseCard,
                        onPin: actions.onPinLiveResponseCard,
                        onRefine: actions.onRefineLiveResponseCard,
                        onDismiss: actions.onDismissLiveResponseCard
                    )
                }
                Hairline()
                QuickAssistExperimentRows(
                    activeExperiment: state.activeExperiment,
                    experimentComparison: state.experimentComparison,
                    hasTurns: state.hasTurns && state.interruptedResponse == nil && !state.isLoading,
                    onCreateExperiment: actions.onCreateExperiment,
                    onCompareExperiment: actions.onCompareExperiment,
                    onAdoptExperiment: actions.onAdoptExperiment,
                    onClearExperiment: actions.onClearExperiment
                )
            }
        }
    }

    @ViewBuilder
    private var threadRow: some View {
        if let threadID = state.activeThreadID, !threadID.isEmpty {
            QuickAssistToolRow(
                "Active thread",
                detail: state.responseCount == 1 ? "1 turn" : "\(state.responseCount) turns",
                systemImage: "bubble.left.and.bubble.right"
            ) {
                Button("Open timeline") { actions.onOpenTimeline(threadID) }
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
        } else {
            QuickAssistToolRow(
                "No thread yet",
                detail: "Generate to start one, or pick a thread in the drawer.",
                systemImage: "bubble.left.and.bubble.right"
            )
        }
    }
}
