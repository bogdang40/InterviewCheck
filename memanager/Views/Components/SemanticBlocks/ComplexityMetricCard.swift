import SwiftUI

/// Complexity stays a readable claim with its explanation, not a success metric.
struct ComplexityMetricCard: View {
    let analysis: ComplexityAnalysis

    var body: some View {
        let presentation = ComplexityNotationPresenter.presentation(for: analysis)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.lg) {
                Text(presentation.label).font(OverlayType.heading)
                Text(presentation.value).font(OverlayType.metricValue)
            }
            .foregroundStyle(OverlayPalette.textPrimary)
            if let caption = presentation.caption {
                Text(caption).font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
