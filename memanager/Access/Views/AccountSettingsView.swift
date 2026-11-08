import SwiftUI

/// Settings page: who is signed in, what they are entitled to, billing, the
/// owner license, and the server address.
struct AccountSettingsView: View {
    @ObservedObject private var controller: AccessController
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isCreatingAccount = false
    @State private var showsOwnerLicense = false
    @State private var confirmsSignOut = false
    @State private var showsServer = false

    @MainActor
    init(controller: AccessController? = nil) {
        _controller = ObservedObject(wrappedValue: controller ?? .shared)
    }

    private var hasServerSession: Bool { controller.token != nil }

    private var canManageBilling: Bool {
        hasServerSession && (controller.serverSnapshot?.subscription != nil || controller.serverSnapshot?.entitlement.source == .subscription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            if let notice = AccountPresentation.offlineNotice(state: controller.state, ownerLicense: controller.ownerLicense) {
                ToneBanner(tone: .warning, message: notice)
            }
            if controller.isUnlockedByOwnerLicense {
                ToneBanner(tone: .info, message: "App access on this Mac is provided by the owner license. Server account status is shown separately below.")
            }

            SettingsSection("Account", trailing: {
                if controller.isBusy { ProgressView().controlSize(.mini) }
            }) {
                if let snapshot = controller.serverSnapshot ?? controller.snapshot {
                    SettingsValueRow(title: "Email", value: snapshot.user.email)
                    SettingsValueRow(title: "Role", value: AccountPresentation.roleDescription(snapshot.user))
                    SettingsValueRow(title: "Access", value: AccountPresentation.accessDescription(snapshot))
                    if let subscription = snapshot.subscription {
                        SettingsValueRow(title: "Subscription", value: AccountPresentation.subscriptionDescription(subscription))
                    }
                } else {
                    SettingsRow(title: "Status", helper: AccountPresentation.stateDescription(controller.state)) {
                        let badge = AccountPresentation.stateBadge(controller.state)
                        ToneBadge(text: badge.text, tone: badge.tone)
                    }
                }

                SettingsRow(title: "Session", layout: .adaptive) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Button("Refresh") { Task { await controller.refresh() } }
                            .buttonStyle(.overlay(.secondary, size: .small))
                            .disabled(controller.isBusy)
                        if canManageBilling {
                            Button("Manage billing") { Task { await controller.openBillingPortal() } }
                                .buttonStyle(.overlay(.secondary, size: .small))
                                .disabled(controller.isBusy)
                        }
                        if hasServerSession {
                            Button("Sign out") { confirmsSignOut = true }
                                .buttonStyle(.overlay(.destructive, size: .small))
                        }
                    }
                }
            }

            if let message = controller.errorMessage, hasServerSession {
                ToneBanner(tone: .critical, message: message)
            }

            if !hasServerSession {
                SettingsSection(
                    "Server account",
                    footer: AccountPresentation.serverAccountHint(isUnlockedByOwnerLicense: controller.isUnlockedByOwnerLicense)
                ) {
                    AccessCredentialForm(controller: controller, isCreatingAccount: $isCreatingAccount)
                        .padding(DesignTokens.Spacing.md)
                }
            }

            SettingsSection("Owner license") {
                SettingsRow(title: controller.isUnlockedByOwnerLicense ? "This Mac has owner access" : "Device bound access",
                            helper: "Import, inspect, or remove a license separately from your server account.", layout: .adaptive) {
                    Button("Open owner license") { showsOwnerLicense = true }
                        .buttonStyle(.overlay(.secondary, size: .small))
                }
            }

            DisclosureCard("Server details", systemImage: "network", isExpanded: $showsServer) {
                AccessServerField(settings: settings)
                    .padding(DesignTokens.Spacing.md)
            }
        }
        .sheet(isPresented: $showsOwnerLicense) {
            OwnerLicenseSheet(controller: controller)
        }
        .confirmationDialog("Sign out of the server account?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await controller.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(controller.ownerLicense.license != nil
                 ? "Your owner license will continue to provide access on this Mac."
                 : "The current session will end and account verification will be required to continue.")
        }
    }
}
