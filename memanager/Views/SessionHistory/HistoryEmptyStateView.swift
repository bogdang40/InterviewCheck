import SwiftUI

/// Compact empty state used inside cards, drawers, and lists where the
/// full screen `OverlayEmptyState` would be too loud. Keeps an optional
/// call to action.
struct HistoryEmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(OverlayType.display)
                .foregroundStyle(OverlayPalette.textTertiary)
            Text(title)
                .font(OverlayType.heading)
                .foregroundStyle(OverlayPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.overlay(.secondary, size: .small))
                    .padding(.top, DesignTokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.lg)
        .overlayCard(.base)
    }
}

/// Shown in a detail pane when no session is selected.
struct HistorySelectionEmptyState: View {
    var body: some View {
        OverlayEmptyState(
            systemImage: "cursorarrow.click.2",
            title: "Pick a session",
            message: "Its overview, timeline, replay, and debrief appear here."
        )
    }
}
