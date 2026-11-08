import AppKit
import SwiftUI

/// The interview shortcuts that work while the video call is in front.
struct ShortcutsSettingsTab: View {
    @State private var enabled = GlobalShortcuts.shared.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Use these shortcuts while another app is in front", isOn: $enabled)
                    .onChange(of: enabled) { _, value in GlobalShortcuts.shared.isEnabled = value }
                ForEach(GlobalShortcuts.all, id: \.id) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.display).font(.body.monospaced())
                    }
                }
            } header: {
                Text("During an interview")
            } footer: {
                Text("They are active only while an interview is running. macOS sends just these two key combinations to \(AppBrand.name), so no Accessibility permission is needed and no other typing is seen.")
            }
            Section("In the app") {
                LabeledContent("New Interview", value: "\u{2318}N")
                LabeledContent("New Role", value: "\u{21E7}\u{2318}N")
                LabeledContent("Start Interview", value: "\u{2318}R")
                LabeledContent("Live Companion", value: "\u{2325}\u{2318}L")
                LabeledContent("Settings", value: "\u{2318},")
            }
        }
        .formStyle(.grouped)
    }
}

/// The owner license or account that unlocks the app.
struct LicenseSettingsTab: View {
    @ObservedObject private var access = AccessController.shared
    @State private var isImporting = false

    var body: some View {
        Form {
            Section("This Mac") {
                switch access.ownerLicense {
                case .valid(let license):
                    LabeledContent("Owner license", value: "Valid")
                    LabeledContent("Licensed to", value: license.email)
                    LabeledContent("Expires", value: license.expiresAt ?? "Never")
                case .invalid(let error):
                    LabeledContent("Owner license", value: "Not valid: \(String(describing: error))")
                case .none:
                    LabeledContent("Owner license", value: "None")
                }
                LabeledContent("License file", value: access.ownerLicenseLocation)
                HStack {
                    Button("Install License File\u{2026}") { isImporting = true }
                    if access.ownerLicense.license != nil {
                        Button("Remove License", role: .destructive) { Task { await access.removeOwnerLicense() } }
                    }
                }
            }
            Section("Account") {
                LabeledContent("Status", value: statusText)
                if access.serverSnapshot != nil {
                    Button("Sign Out") { Task { await access.signOut() } }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data, .json]) { result in
            if case .success(let url) = result {
                Task { await access.installOwnerLicense(from: url) }
            }
        }
    }

    private var statusText: String {
        switch access.state {
        case .checking: return "Checking\u{2026}"
        case .allowed(_, let offline): return offline ? "Active (offline)" : "Active"
        case .signedOut: return "Signed out"
        case .paywall: return "Subscription needed"
        case .unreachable: return "Server unreachable"
        }
    }
}

struct AboutSettingsTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(AppBrand.name).font(.title.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Helps interviewers notice answers read from AI tools. Scores are signals to follow up on, not proof.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
