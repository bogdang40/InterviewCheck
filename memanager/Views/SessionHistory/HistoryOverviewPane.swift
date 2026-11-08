import SwiftUI

/// Overview of the selected session: the metric ribbon, the summary with
/// its action items and resume bar, provider comparison, the 30 day
/// provider stats, and skill progression.
struct HistoryOverviewPane: View {
    @ObservedObject private var controller = SessionController.shared
    let sessionID: String?
    let providerStats: [ProviderStatsRecord]
    @State private var showsTechnicalDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SessionSummaryView(sessionID: sessionID)
                DisclosureCard("Technical details", systemImage: "chart.bar", isExpanded: $showsTechnicalDetails) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        Text("Selected session")
                            .font(OverlayType.captionStrong)
                            .foregroundStyle(OverlayPalette.textSecondary)
                        SessionSummaryRibbon(metrics: controller.currentSessionMetrics)
                        ProviderComparisonCard(providers: controller.currentProviderBreakdown)
                        Text("Provider statistics across the last 30 days")
                            .font(OverlayType.captionStrong)
                            .foregroundStyle(OverlayPalette.textSecondary)
                        ProviderStatsCardGroup(stats: providerStats)
                        SkillProgressionSection(report: controller.currentSkillReport)
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
    }
}
