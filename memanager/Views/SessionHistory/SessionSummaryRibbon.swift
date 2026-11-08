import SwiftUI

/// Metric tiles read first on the overview: turns, verified percent,
/// latency, coach findings, and unsupported claims.
struct SessionSummaryRibbon: View {
    let metrics: DebriefMetrics?

    var body: some View {
        if let metrics {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(SessionMetricsFormatter.tiles(for: metrics)) { tile in
                        MetricTile(value: tile.value, label: tile.label, tone: tile.tone, systemImage: tile.systemImage)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "chart.bar")
                    .font(OverlayType.caption)
                Text("Metrics appear once the session has Quick Assist turns.")
                    .font(OverlayType.caption)
            }
            .foregroundStyle(OverlayPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
            .overlayCard(.base)
        }
    }
}
