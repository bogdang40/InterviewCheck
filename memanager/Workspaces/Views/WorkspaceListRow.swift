import SwiftUI

/// Row content for one workspace: stage symbol, title, role line, and the
/// Active badge when Quick Assist is grounded in it.
struct WorkspaceListRow: View {
    let workspace: JobWorkspace
    let isActive: Bool

    private var tone: OverlayTone {
        WorkspaceStatusPresentation.tone(for: workspace.status)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: workspace.status.systemImage)
                .font(OverlayType.callout)
                .foregroundStyle(tone == .neutral ? OverlayPalette.textSecondary : tone.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(workspace.displayTitle)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                Text(WorkspaceStatusPresentation.subtitle(for: workspace))
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            if isActive {
                ToneBadge(text: "Active", tone: .success, systemImage: "checkmark")
            }
        }
        .opacity(WorkspaceStatusPresentation.rowOpacity(isArchived: workspace.isArchived))
    }
}
