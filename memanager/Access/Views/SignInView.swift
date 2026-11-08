import SwiftUI

/// Credentials and independent owner licensing are both discoverable at the gate.
struct SignInView: View {
    @ObservedObject var controller: AccessController
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isCreatingAccount: Bool
    @State private var isAdvancedVisible = false
    @State private var showsOwnerLicense = false

    init(controller: AccessController, isCreatingAccount: Bool = false) {
        self.controller = controller
        _isCreatingAccount = State(initialValue: isCreatingAccount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                SurfaceHeader(isCreatingAccount ? "Create account" : "Sign in",
                              subtitle: isCreatingAccount ? "Create a server account for Abley." : "Sign in to verify your account access.")
                AccessCredentialForm(controller: controller, isCreatingAccount: $isCreatingAccount)
                if case .invalid(let error) = controller.ownerLicense {
                    ToneBanner(tone: .warning, title: "Owner license needs attention", message: error.localizedDescription)
                }
                Hairline()
                Button { showsOwnerLicense = true } label: {
                    Label("Owner license", systemImage: "key")
                }
                .buttonStyle(.overlaySecondary)
                Text("A valid owner license provides access on this Mac independently of a server account.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureCard("Advanced server details", systemImage: "network", isExpanded: $isAdvancedVisible) {
                    AccessServerField(settings: settings)
                }
        }
        .sheet(isPresented: $showsOwnerLicense) { OwnerLicenseSheet(controller: controller) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
