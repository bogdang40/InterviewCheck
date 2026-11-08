import SwiftUI

struct OwnerLicensePage: View {
    @ObservedObject var controller: AccessController
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Button("Back", action: onBack)
                .buttonStyle(.overlay(.ghost, size: .small))
                .accessibilityLabel("Back from owner license")
            SurfaceHeader("Owner license", systemImage: "key", subtitle: "Access bound to this Mac.")
            OwnerLicenseControls(controller: controller)
            if let error = controller.errorMessage {
                ToneBanner(tone: .critical, message: error)
            }
            Text("A valid license grants access on this Mac without a server account. Server administration still requires sign in.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OwnerLicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AccessController

    var body: some View {
        ScrollView {
            OwnerLicensePage(controller: controller, onBack: { dismiss() })
                .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: 480, height: 560)
        .background(OverlayPalette.readingSurface)
        .environment(\.settingsBreakpoint, .compact)
    }
}
