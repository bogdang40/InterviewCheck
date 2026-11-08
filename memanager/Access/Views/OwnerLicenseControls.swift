import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The installed license and its device binding, without signing-tool instructions.
struct OwnerLicenseControls: View {
    @ObservedObject var controller: AccessController
    @State private var isRemoveConfirmationPresented = false
    @State private var showsFileDetails = false

    private var isValid: Bool { controller.ownerLicense.license != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            SettingsSection {
                SettingsRow(title: "Status", helper: statusDescription, layout: .adaptive) {
                    ToneBadge(text: statusBadge.text, tone: statusBadge.tone, systemImage: statusBadge.systemImage)
                }
                SettingsRow(title: "This Mac", helper: "The identifier this license must match.", layout: .adaptive) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text(controller.deviceID ?? "Identifier unavailable")
                            .font(OverlayType.mono)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button("Copy identifier") {
                            guard let deviceID = controller.deviceID else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceID, forType: .string)
                        }
                        .buttonStyle(.overlay(.secondary, size: .small))
                        .disabled(controller.deviceID == nil)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.sm) { licenseActions }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) { licenseActions }
            }
            DisclosureCard("License details", systemImage: "doc.text", isExpanded: $showsFileDetails) {
                Text(controller.ownerLicenseLocation)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Remove the owner license from this Mac?", isPresented: $isRemoveConfirmationPresented, titleVisibility: .visible) {
            Button("Remove license", role: .destructive) { Task { await controller.removeOwnerLicense() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac will need a signed in server account with active access. Keep your license file if you may need to import it again.")
        }
    }

    @ViewBuilder
    private var licenseActions: some View {
        Button("Import license file", action: presentImportPanel)
            .buttonStyle(.overlay(.primary, size: .small))
            .disabled(controller.isBusy)
        Button("Check again") { Task { await controller.refresh() } }
            .buttonStyle(.overlay(.secondary, size: .small))
            .disabled(controller.isBusy)
        if isValid {
            Button("Remove license") { isRemoveConfirmationPresented = true }
                .buttonStyle(.overlay(.destructive, size: .small))
                .disabled(controller.isBusy)
        }
        if controller.isBusy { ProgressView().controlSize(.small) }
    }

    private var statusDescription: String {
        switch controller.ownerLicense {
        case .none: return "No owner license is installed."
        case .valid(let license):
            var text = "Valid for \(license.email) on this Mac"
            if let expiry = license.expiresAtDate {
                text += ", until \(expiry.formatted(date: .abbreviated, time: .omitted))"
            }
            return text + "."
        case .invalid(let error): return error.localizedDescription
        }
    }

    private var statusBadge: (text: String, tone: OverlayTone, systemImage: String) {
        switch controller.ownerLicense {
        case .none: return ("No license", .neutral, "circle.dashed")
        case .valid: return ("Valid", .success, "checkmark.seal")
        case .invalid: return ("Invalid", .warning, "exclamationmark.triangle")
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose an owner license file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await controller.installOwnerLicense(from: url)
        }
    }
}
