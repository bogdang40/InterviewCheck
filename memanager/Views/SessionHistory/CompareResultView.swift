import SwiftUI

/// Highlights and the two metric columns of a thread comparison.
struct CompareResultView: View {
    let comparison: WorkstreamThreadComparison

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Comparison describes recorded responses and request metrics. It is not proof of correctness.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            if !comparison.highlights.isEmpty {
                FieldLabel(text: "Highlights")
                ForEach(comparison.highlights, id: \.self) { line in
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        Circle()
                            .fill(OverlayPalette.accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, DesignTokens.Spacing.xs)
                        Text(line)
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                column(comparison.left)
                column(comparison.right)
            }
        }
    }

    private func column(_ metrics: WorkstreamThreadMetrics) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(metrics.title)
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineLimit(2)
            HStack(spacing: DesignTokens.Spacing.sm) {
                stat("\(metrics.turnCount)", "turns")
                stat("\(metrics.errorCount)", "errors", tone: metrics.errorCount > 0 ? .critical : .neutral)
                stat(metrics.averageDurationMs.map { "\($0)ms" } ?? "n/a", "avg")
            }
            if let snippet = metrics.latestResponseSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                Text(snippet)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }

    private func stat(_ value: String, _ label: String, tone: OverlayTone = .neutral) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Text(value)
                .font(OverlayType.monoMicro)
                .foregroundStyle(tone == .neutral ? OverlayPalette.textPrimary : tone.color)
            Text(label)
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
    }
}
