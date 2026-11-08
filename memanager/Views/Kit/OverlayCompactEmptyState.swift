import SwiftUI

/// Empty state sized for a 250 point drawer column: one symbol, a heading,
/// a caption, and an optional action. Kit candidate: OverlayEmptyState
/// compact variant.
struct OverlayCompactEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var action: EmptyStateAction? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(OverlayPalette.accentTint)
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .font(OverlayType.title)
                    .foregroundStyle(OverlayPalette.accent)
            }
            Text(title)
                .font(OverlayType.heading)
                .foregroundStyle(OverlayPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.action) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(action.title)
                        if let shortcut = action.shortcut {
                            KeyCap(shortcut: shortcut)
                        }
                    }
                }
                .buttonStyle(.overlay(.secondary, size: .small))
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity)
    }
}
