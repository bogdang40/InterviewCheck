import SwiftUI

/// Sparklines for the four tracked skill metrics across sessions, with the
/// trend direction next to each.
struct SkillProgressionSection: View {
    let report: SkillProgressionReport

    @State private var isExpanded = true

    var body: some View {
        DisclosureCard(
            "Skill progression",
            systemImage: "chart.line.uptrend.xyaxis",
            count: report.isEmpty ? nil : report.snapshots.count,
            isExpanded: $isExpanded
        ) {
            if report.isEmpty {
                Text("Not enough sessions yet. Trends appear after a few debriefs.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(SkillMetricCatalog.tracked) { metric in
                        row(for: metric)
                    }
                }
            }
        }
    }

    private func row(for metric: SkillMetricDescriptor) -> some View {
        let trend = SkillMetricCatalog.trend(for: metric.key, in: report)
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Text(metric.label)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .frame(width: 96, alignment: .leading)
            SparklineView(values: SkillMetricCatalog.values(for: metric.key, in: report), tone: trend.tone)
            Image(systemName: trend.systemImage)
                .font(OverlayType.captionStrong)
                .foregroundStyle(trend.tone == .neutral ? OverlayPalette.textTertiary : trend.tone.color)
                .frame(width: 16)
                .accessibilityLabel(trend.rawValue)
        }
    }
}
