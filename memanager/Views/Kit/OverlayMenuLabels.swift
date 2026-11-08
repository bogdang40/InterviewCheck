import SwiftUI

/// Label for a `Menu` that should read like a secondary button: title,
/// optional symbol, and a chevron. Kit candidate: OverlayMenuLabel.
struct OverlayMenuLabel: View {
    let title: String
    var systemImage: String? = nil
    var isActive: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(OverlayType.captionStrong)
            }
            Text(title)
                .font(OverlayType.callout)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .foregroundStyle(isActive ? OverlayPalette.accent : OverlayPalette.textPrimary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(minHeight: 24)
        .background(shape.fill(isActive ? OverlayPalette.accentTint : OverlayPalette.surfaceRaised))
        .overlay(shape.stroke(isActive ? OverlayPalette.accentStroke : OverlayPalette.hairlineStrong, lineWidth: 1))
        .contentShape(shape)
    }
}

/// Square icon label for a `Menu`, matching `OverlayIconButtonStyle` so a
/// menu toggle sits beside icon buttons without a seam. Kit candidate:
/// OverlayIconMenuLabel.
struct OverlayIconMenuLabel: View {
    let systemImage: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var size: CGFloat = 26

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(OverlayType.captionStrong)
            .foregroundStyle(isActive ? OverlayPalette.accent : OverlayPalette.textSecondary)
            .frame(width: size, height: size)
            .background(shape.fill(isActive ? OverlayPalette.accentTint : OverlayPalette.surfaceRaised))
            .overlay(shape.stroke(isActive ? OverlayPalette.accentStroke : OverlayPalette.hairlineStrong, lineWidth: 1))
            .opacity(isDimmed ? 0.45 : 1)
            .contentShape(shape)
    }
}
