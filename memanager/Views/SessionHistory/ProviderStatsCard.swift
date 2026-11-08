import SwiftUI

/// Aggregate figures for one provider: calls, successes, errors, average
/// latency, and success rate as a tile row.
struct ProviderStatsCard: View {
    let aggregate: ProviderStatsAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "cpu")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                Text(aggregate.provider)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    MetricTile(value: "\(aggregate.calls)", label: "Calls")
                    MetricTile(value: "\(aggregate.successes)", label: "Success", tone: .success)
                    MetricTile(value: "\(aggregate.errors)", label: "Errors", tone: aggregate.errors > 0 ? .critical : .neutral)
                    MetricTile(value: String(format: "%.0fms", aggregate.averageDurationMs), label: "Average")
                    MetricTile(value: String(format: "%.1f%%", aggregate.successRate), label: "Rate", tone: .info)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }
}
