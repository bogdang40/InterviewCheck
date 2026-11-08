import SwiftUI

/// Admin only page. Lists every account with its entitlement and offers the
/// grants and role changes that live on the server's users table.
struct AdminPanelView: View {
    @StateObject private var model = AdminPanelModel()
    @ObservedObject private var access = AccessController.shared
    @State private var pendingChange: AdminChangeConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            if access.token == nil {
                OverlayEmptyState(systemImage: "person.badge.key", title: "Sign in to manage accounts",
                                  message: "A local owner license grants app access. Server administration requires an authenticated server account.",
                                  primary: EmptyStateAction(title: "Open Account") { OverlayNavigator.shared.showSettings(.account) })
            } else if controllerNeedsAdminAccess {
                OverlayEmptyState(systemImage: "person.badge.key", title: "Server administrator access required",
                                  message: "The signed in server account must have an administrator role. Local owner access does not assign a server role.",
                                  primary: EmptyStateAction(title: "Open Account") { OverlayNavigator.shared.showSettings(.account) })
            } else {
            if let stats = model.stats {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    MetricTile(value: "\(stats.totalUsers)", label: "Users", systemImage: "person.2")
                    MetricTile(value: "\(stats.admins)", label: "Admins", systemImage: "person.badge.key")
                    MetricTile(value: "\(stats.liveSubscriptions)", label: "Subscribed", tone: .success, systemImage: "creditcard")
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                OverlaySearchField(placeholder: "Search by email", text: $model.query)
                    .onSubmit { reload() }
                Button("Search", action: reload)
                    .buttonStyle(.overlay(.secondary, size: .small))
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.overlayIcon(size: 24))
                .disabled(model.isLoading)
                .help("Reload")
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if let message = model.message {
                ToneBanner(tone: model.messageIsError ? .critical : .neutral, message: message)
            }

            list
            }
        }
        .task { if !controllerNeedsAdminAccess { await model.load() } }
        .onChange(of: access.serverSnapshot?.user) { _, _ in
            if !controllerNeedsAdminAccess { reload() }
        }
        .confirmationDialog(pendingChange?.title ?? "Change account access?", isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }), titleVisibility: .visible) {
            if let change = pendingChange {
                Button(change.actionTitle, role: change.isDestructive ? .destructive : nil) {
                    pendingChange = nil
                    Task { await perform(change.action, on: change.user) }
                }
            }
            Button("Cancel", role: .cancel) { pendingChange = nil }
        } message: {
            Text(pendingChange?.message ?? "")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.users.isEmpty {
            if !model.isLoading {
                Text("No accounts match.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }
        } else {
            SettingsSection("Accounts", trailing: { CountBadge(count: model.users.count) }) {
                ForEach(model.users) { user in
                    AdminUserRow(view: user, isSelf: user.id == access.serverSnapshot?.user.id, isUpdating: model.updatingUserIDs.contains(user.id)) { action in
                        pendingChange = AdminChangeConfirmation(user: user, action: action)
                    }
                }
            }
            if model.nextCursor != nil {
                Button("Load more") { Task { await model.load(reset: false) } }
                    .buttonStyle(.overlay(.ghost, size: .small))
                    .disabled(model.isLoading)
            }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private var controllerNeedsAdminAccess: Bool {
        access.token != nil && access.serverSnapshot?.user.isAdmin != true
    }

    private func perform(_ action: AdminUserRow.Action, on user: AdminUserView) async {
        switch action {
        case .grant(let days): await model.grant(days: days, to: user)
        case .clearGrant: await model.clearGrant(for: user)
        case .setRole(let role): await model.setRole(role, for: user)
        case .setDisabled(let disabled): await model.setDisabled(disabled, for: user)
        }
    }
}

struct AdminChangeConfirmation {
    let user: AdminUserView
    let action: AdminUserRow.Action
    var title: String { "\(actionTitle) for \(user.user.email)?" }
    var actionTitle: String {
        switch action {
        case .grant(let days): return "Grant \(days) days"
        case .clearGrant: return "Clear complimentary access"
        case .setRole(let role): return role == .admin ? "Make admin" : "Remove admin"
        case .setDisabled(let disabled): return disabled ? "Disable account" : "Enable account"
        }
    }
    var isDestructive: Bool {
        switch action {
        case .clearGrant, .setRole(.user), .setDisabled(true): return true
        default: return false
        }
    }
    var message: String {
        switch action {
        case .grant: return "The complimentary access expiry will be replaced with a new date measured from today."
        case .clearGrant: return "Access from this grant will end. Other valid entitlement sources remain governed by the server."
        case .setRole(.admin): return "This account will be allowed to manage other accounts and grants on the server."
        case .setRole(.user): return "This account will lose server administration privileges."
        case .setDisabled(true): return "The account will be blocked from using its server access."
        case .setDisabled(false): return "The server will permit access according to the account's current entitlement."
        }
    }
}
