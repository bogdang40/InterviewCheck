import AppKit
import SwiftUI

/// Summary banner and one row per system permission with its state and a
/// way to grant it.
struct PermissionsSettingsView: View {
    @ObservedObject private var permissionManager = PermissionManager.shared

    private var summary: (tone: OverlayTone, title: String, message: String) {
        PermissionRowState.summary(missingCount: permissionManager.missingPermissions.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            ToneBanner(
                tone: summary.tone,
                title: summary.title,
                message: summary.message,
                actions: [BannerAction(title: "Refresh") { permissionManager.refreshAllStatuses() }]
            )

            SettingsSection("System access", footer: "Some permissions take effect only after \(AppBrand.name) is restarted.") {
                ForEach(PermissionType.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: permissionManager.status(for: permission)
                    ) {
                        if permissionManager.status(for: permission) == .notDetermined {
                            permissionManager.requestPermission(permission) { _ in
                                Task { @MainActor in permissionManager.refreshAllStatuses() }
                            }
                        } else {
                            permissionManager.openSettings(for: permission)
                        }
                    }
                }
            }
        }
        .onAppear { permissionManager.refreshAllStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.refreshAllStatuses()
        }
    }
}

/// One permission: status dot, name and reason, and either a granted badge
/// or the button that opens System Settings.
struct PermissionRow: View {
    @Environment(\.settingsBreakpoint) private var breakpoint
    let permission: PermissionType
    let status: PermissionStatus
    let onGrant: () -> Void

    var body: some View {
        let layout = breakpoint == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DesignTokens.Spacing.md))
        layout {
            if breakpoint != .compact {
                StatusDot(state: PermissionRowState.dotState(for: status), size: 7)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if breakpoint == .compact {
                        StatusDot(state: PermissionRowState.dotState(for: status), size: 7)
                    }
                    Image(systemName: permission.icon)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                    Text(permission.displayName)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                }
                Text(permission.description)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .restricted {
                    Text("This access is restricted by system policy. Review your Mac's restrictions.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
            }

            if breakpoint != .compact { Spacer(minLength: DesignTokens.Spacing.md) }

            if status.isGranted {
                ToneBadge(text: status.displayText, tone: .success, systemImage: "checkmark")
            } else {
                VStack(alignment: breakpoint == .compact ? .leading : .trailing, spacing: DesignTokens.Spacing.xs) {
                    ToneBadge(text: status.displayText, tone: PermissionRowState.badgeTone(for: status))
                    Button(status == .notDetermined ? "Request access" : "Open System Settings", action: onGrant)
                        .buttonStyle(.overlay(.secondary, size: .small))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}
