import SwiftUI

/// This state has no usable offline grant. Recovery must not promise otherwise.
struct AccessUnreachableView: View {
    @ObservedObject var controller: AccessController
    @ObservedObject private var settings = SettingsManager.shared
    let message: String
    @State private var showsServer = false
    @State private var showsOwnerLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            if showsOwnerLicense {
                OwnerLicensePage(controller: controller, onBack: { showsOwnerLicense = false })
            } else {
                SurfaceHeader("Cannot verify access", systemImage: "wifi.exclamationmark",
                              subtitle: "The access server could not be reached. No usable offline grant is available.")
                ToneBanner(tone: .warning, message: message)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Retry") { Task { await controller.refresh() } }
                        .buttonStyle(.overlayPrimary)
                        .disabled(controller.isBusy)
                    Button("Sign out") { Task { await controller.signOut() } }
                        .buttonStyle(.overlaySecondary)
                    if controller.isBusy { ProgressView().controlSize(.small) }
                }
                DisclosureCard("Server details", systemImage: "network", isExpanded: $showsServer) {
                    AccessServerField(settings: settings)
                    if !AccessServerAddress.isEditable {
                        Text("The release server address is read only.")
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textSecondary)
                    }
                }
                Button { showsOwnerLicense = true } label: {
                    Label("Owner license", systemImage: "key")
                }
                .buttonStyle(.overlaySecondary)
                Text("A valid owner license works independently of the access server.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.base, padding: DesignTokens.Spacing.lg)
    }
}
