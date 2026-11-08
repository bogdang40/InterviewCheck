import AppKit
import SwiftUI

/// Name, version, one line about the app, and the quit action.
struct AboutSettingsView: View {
    @State private var showsBuildDetails = false
    private var version: String {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        return "Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                Image("AbleyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(AppBrand.name)
                        .font(OverlayType.display)
                        .foregroundStyle(OverlayPalette.textPrimary)
                    Text("Version \(version)")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                }
            }

            Text("An overlay for focused technical conversations and preparation.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureCard("Build details", systemImage: "info.circle", isExpanded: $showsBuildDetails) {
                SettingsValueRow(title: "Version", value: version)
                SettingsValueRow(title: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unavailable")
            }

            SettingsSection("Quit") {
                SettingsRow(title: "Quit \(AppBrand.name)", helper: "Ends the interview and closes the app.") {
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Quit")
                            KeyCap(shortcut: ShortcutCatalog.quit)
                        }
                    }
                    .buttonStyle(.overlay(.destructive, size: .small))
                }
            }
        }
    }
}
