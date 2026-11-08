import SwiftUI

/// Branch experiments: compare candidates, adopt the winner, or clear.
struct QuickAssistExperimentRows: View {
    let activeExperiment: QuickAssistExperiment?
    let experimentComparison: WorkstreamThreadComparison?
    let hasTurns: Bool
    let onCreateExperiment: () -> Void
    let onCompareExperiment: () -> Void
    let onAdoptExperiment: (String) -> Void
    let onClearExperiment: () -> Void

    var body: some View {
        if let experiment = activeExperiment, !experiment.candidates.isEmpty {
            activeRows(for: experiment)
        } else {
            QuickAssistToolRow(
                "Branch",
                detail: "Compare alternative answers without losing the main thread.",
                systemImage: "arrow.triangle.branch"
            ) {
                Button("Branch from turn", action: onCreateExperiment)
                    .buttonStyle(.overlay(.secondary, size: .small))
                    .disabled(!hasTurns)
            }
        }
    }

    @ViewBuilder
    private func activeRows(for experiment: QuickAssistExperiment) -> some View {
        QuickAssistToolRow(
            "Experiment",
            detail: experiment.candidates.count == 1 ? "1 candidate" : "\(experiment.candidates.count) candidates",
            systemImage: "arrow.triangle.branch"
        ) {
            Button("Compare", action: onCompareExperiment)
                .buttonStyle(.overlay(.ghost, size: .small))
            if let winner = experiment.candidates.first(where: \.isWinner) {
                Button("Adopt winner") { onAdoptExperiment(winner.threadId) }
                    .buttonStyle(.overlay(.secondary, size: .small))
            }
            Button("Clear", action: onClearExperiment)
                .buttonStyle(.overlay(.ghost, size: .small))
        }

        ForEach(experiment.candidates, id: \.id) { candidate in
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(candidate.label)
                        .font(OverlayType.captionStrong)
                        .foregroundStyle(OverlayPalette.textPrimary)
                    Spacer(minLength: 0)
                    if candidate.isWinner {
                        ToneBadge(text: "Winner", tone: .success, systemImage: "checkmark")
                    }
                }
                Text(candidate.score.rationale)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, DesignTokens.Spacing.xl)
        }

        if let experimentComparison {
            ForEach(experimentComparison.highlights.prefix(2), id: \.self) { line in
                Text(line)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DesignTokens.Spacing.xl)
            }
        }
    }
}
