import SwiftUI

/// One node on the neighborhood map: a small capsule with the kind symbol
/// and label. The centre carries the accent so the eye lands on it first,
/// and every capsule sits on a canvas base so edges end at its border.
struct KnowledgeGraphNodeCapsule: View {
    let node: KnowledgeNode
    let isCenter: Bool

    private static let maximumWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: node.kind.systemImage)
                .font(OverlayType.micro)
            Text(node.label)
                .font(isCenter ? OverlayType.captionStrong : OverlayType.caption)
                .lineLimit(1)
        }
        .foregroundStyle(isCenter ? OverlayPalette.textPrimary : OverlayPalette.textSecondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Capsule().fill(isCenter ? OverlayPalette.accentTint : OverlayPalette.surfaceOverlay))
        .background(Capsule().fill(OverlayPalette.canvas))
        .overlay(Capsule().stroke(isCenter ? OverlayPalette.accentStroke : OverlayPalette.hairlineStrong, lineWidth: 1))
        .frame(maxWidth: Self.maximumWidth)
        .help(node.summary ?? node.kind.displayName)
    }
}
