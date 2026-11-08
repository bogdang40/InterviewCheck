import SwiftUI

/// One journal entry: kind badge, title that expands into the body, date,
/// and a delete control.
struct WorkspaceJournalRow: View {
    let entry: WorkspaceJournalEntry
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ToneBadge(
                    text: entry.kind.displayName,
                    tone: WorkspaceJournalKindPresentation.tone(for: entry.kind),
                    systemImage: entry.kind.systemImage
                )
                Button(action: onToggle) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(entry.title)
                            .font(OverlayType.callout)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isExpanded ? nil : 1)
                        Image(systemName: "chevron.right")
                            .font(OverlayType.micro)
                            .foregroundStyle(OverlayPalette.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.overlayIcon(size: 22, bordered: false))
                .help("Delete entry")
            }
            if isExpanded {
                Text(entry.body)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DesignTokens.Spacing.xs)
                if let sessionID = entry.sessionID {
                    Text("Session \(sessionID)")
                        .font(OverlayType.monoMicro)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .textSelection(.enabled)
                }
                if let turnID = entry.turnID {
                    Text("Turn \(turnID)")
                        .font(OverlayType.monoMicro)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}
