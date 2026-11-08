import SwiftUI

/// The back of the envelope figures as a table the user can read aloud:
/// the metric, its value in monospace with the accent, and the formula that
/// produced it as a caption.
struct EstimationMetricsView: View {
    let metrics: [EstimationMetric]
    let fontSize: CGFloat

    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "number.square")
                        .font(OverlayType.micro)
                        .foregroundStyle(OverlayPalette.textTertiary)
                    FieldLabel(text: "Capacity math")
                }

                Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.lg, verticalSpacing: 0) {
                    GridRow {
                        FieldLabel(text: "Metric")
                        FieldLabel(text: "Value")
                        FieldLabel(text: "Formula")
                    }
                    .padding(.bottom, DesignTokens.Spacing.xs)

                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        Hairline()
                            .gridCellColumns(3)
                            .opacity(index == 0 ? 1 : 0.6)
                        GridRow(alignment: .firstTextBaseline) {
                            Text(metric.name)
                                .font(OverlayType.body(fontSize))
                                .foregroundStyle(OverlayPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(metric.value)
                                .font(OverlayType.mono)
                                .foregroundStyle(OverlayPalette.accent)
                                .textSelection(.enabled)
                            Text(metric.formula ?? "")
                                .font(OverlayType.caption)
                                .foregroundStyle(OverlayPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridCellAnchor(.leading)
                        }
                        .padding(.vertical, DesignTokens.Spacing.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.md, padding: DesignTokens.Spacing.md)
        }
    }
}
