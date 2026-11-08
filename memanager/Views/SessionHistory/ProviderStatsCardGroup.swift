import SwiftUI

/// The 30 day provider stats, one card per provider.
struct ProviderStatsCardGroup: View {
    let stats: [ProviderStatsRecord]

    private var aggregates: [ProviderStatsAggregate] {
        ProviderStatsAggregate.grouped(stats)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Provider stats", systemImage: "chart.bar", subtitle: "Last 30 days across every session", prominence: .heading)
            if aggregates.isEmpty {
                Text("No API calls recorded in the last 30 days.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                ForEach(aggregates) { aggregate in
                    ProviderStatsCard(aggregate: aggregate)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
    }
}
