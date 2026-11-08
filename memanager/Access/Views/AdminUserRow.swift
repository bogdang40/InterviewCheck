import SwiftUI

/// One account in the admin list: email with role badges, a detail line,
/// the entitlement badge, and the actions menu.
struct AdminUserRow: View {
    @Environment(\.settingsBreakpoint) private var breakpoint
    enum Action {
        case grant(days: Int)
        case clearGrant
        case setRole(AccountRole)
        case setDisabled(Bool)
    }

    let view: AdminUserView
    let isSelf: Bool
    var isUpdating = false
    let onAction: (Action) -> Void

    private var entitlement: (text: String, tone: OverlayTone) {
        AdminUserRowPresentation.entitlementBadge(for: view)
    }

    var body: some View {
        let layout = breakpoint == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DesignTokens.Spacing.md))
        layout {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(view.user.email)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(view.user.email)
                        .textSelection(.enabled)
                    if view.user.isAdmin { ToneBadge(text: "Admin", tone: .info) }
                    if view.user.disabled { ToneBadge(text: "Disabled", tone: .critical) }
                    if isSelf { ToneBadge(text: "You", tone: .neutral, style: .outline) }
                }
                Text(AdminUserRowPresentation.detailLine(for: view))
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
            }

            if breakpoint != .compact { Spacer(minLength: DesignTokens.Spacing.sm) }

            ToneBadge(text: entitlement.text, tone: entitlement.tone)

            Menu {
                Button("Grant 30 days") { onAction(.grant(days: 30)) }
                Button("Grant 1 year") { onAction(.grant(days: 365)) }
                Button("Clear complimentary access") { onAction(.clearGrant) }
                    .disabled(view.user.complimentaryUntil == nil)
                Divider()
                if view.user.isAdmin {
                    Button("Remove admin") { onAction(.setRole(.user)) }.disabled(isSelf)
                } else {
                    Button("Make admin") { onAction(.setRole(.admin)) }
                }
                if view.user.disabled {
                    Button("Enable account") { onAction(.setDisabled(false)) }
                } else {
                    Button("Disable account", role: .destructive) { onAction(.setDisabled(true)) }.disabled(isSelf)
                }
            } label: {
                Label(isUpdating ? "Updating" : "Actions", systemImage: "slider.horizontal.3")
                    .font(OverlayType.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isUpdating)
            .help("Actions for \(view.user.email)")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}
