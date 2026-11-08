import SwiftUI

/// A number with its label. Used in summary ribbons, headers, and cards
/// wherever a figure should be read before its meaning.
struct MetricTile: View {
    let value: String
    let label: String
    var tone: OverlayTone = .neutral
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(OverlayType.symbol(10))
                        .foregroundStyle(tone == .neutral ? OverlayPalette.textSecondary : tone.color)
                }
                Text(value)
                    .font(OverlayType.metricValue)
                    .foregroundStyle(tone == .neutral ? OverlayPalette.textPrimary : tone.color)
                    .lineLimit(1)
            }
            Text(label)
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .textCase(.uppercase)
                .kerning(0.3)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(minWidth: 72, alignment: .leading)
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)
    }
}

/// Inline pill pairing a count with a short label.
struct CountPill: View {
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textPrimary)
            Text(label)
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(OverlayPalette.surfaceRaised))
    }
}
