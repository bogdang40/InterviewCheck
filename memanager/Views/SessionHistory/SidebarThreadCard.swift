import SwiftUI

/// One thread in the drawer list: verification dot, title, turn count,
/// tier and coaching chips, preview, and relative time. Branches carry the
/// accent edge.
struct SidebarThreadCard: View {
    let model: QuickAssistThreadRowModel
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onInspect: () -> Void
    var selectionOverride: Bool? = nil

    var body: some View {
        SelectableRow(isSelected: selectionOverride ?? model.isSelected, action: onSelect, accentEdge: model.isBranched) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    QuickAssistVerificationDot(status: model.verificationStatus, size: 6)
                        .frame(width: 8)
                    Text(model.summary.title)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                    CountBadge(count: model.summary.turnCount)
                }
                chips
                if let preview = model.preview {
                    Text(preview)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.relativeTime())
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .padding(.leading, model.isBranched ? DesignTokens.Spacing.xs : 0)
        }
        .contextMenu {
            Button("Open in timeline", action: onInspect)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if model.tier != nil || model.coachingCount > 0 || model.isActive || model.isPendingDeletion || model.isBranched {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let tier = model.tier {
                    ToneBadge(text: tier.badgeLabel, tone: tier.badgeTone, style: .outline, monospaced: true)
                }
                if model.coachingCount > 0 {
                    ToneBadge(text: "\(model.coachingCount)", tone: .warning, systemImage: "exclamationmark.triangle")
                        .help(model.coachingCount == 1 ? "1 coach finding" : "\(model.coachingCount) coach findings")
                }
                if model.isBranched {
                    ToneBadge(text: "Branch", tone: .info, systemImage: "arrow.triangle.branch")
                }
                if model.isActive {
                    ToneBadge(text: "Active", tone: .info)
                }
                if model.isPendingDeletion {
                    ToneBadge(text: "Delete?", tone: .critical, systemImage: "trash")
                }
            }
        }
    }
}
