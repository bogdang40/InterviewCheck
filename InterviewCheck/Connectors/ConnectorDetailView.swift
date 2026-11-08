import InterviewCheckConnectors
import SwiftUI
import UniformTypeIdentifiers

/// One system: what it brings, how to connect it, and its sync state.
struct ConnectorDetailView: View {
    let kind: ConnectorKind
    @ObservedObject private var connectors = ConnectorManager.shared
    @State private var fields: [String: String] = [:]
    @State private var isWorking = false
    @State private var message: String?
    @State private var failed = false
    @State private var isImportingInvite = false
    @State private var confirmDisconnect = false

    private var descriptor: ConnectorDescriptor { kind.descriptor }
    private var account: ConnectorManager.Account? { connectors.account(kind) }
    private var isAvailable: Bool { ConnectorFactory.implemented.contains(kind) || kind == .icsFile }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(descriptor.name).font(.title2.weight(.semibold))
                    Text(descriptor.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(descriptor.capabilities, id: \.self) { Tag(text: $0.title, color: .accentColor) }
                    }
                }
                .padding(.vertical, 4)
            }

            if let account {
                connectedSection(account)
            } else if !isAvailable {
                Section {
                    Label("Not available in this build yet.", systemImage: "clock")
                    Text(descriptor.setup).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                setupSection
            }

            if let message {
                Section {
                    Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if let docs = descriptor.docsURL { Link("\(descriptor.name) API documentation", destination: docs) }
                Text(privacyNote).font(.caption).foregroundStyle(.secondary)
                if descriptor.isUntestedAgainstLiveAccount {
                    Text("Beta: built from \(descriptor.name)'s published API. Check the first sync's interviews look right.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImportingInvite, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importInvites(urls)
        }
        .confirmationDialog("Disconnect \(descriptor.name)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { connectors.disconnect(kind) }
        } message: {
            Text("Its saved key or sign-in and the interviews it brought in are removed from this Mac.")
        }
    }

    // MARK: - Sections

    private func connectedSection(_ account: ConnectorManager.Account) -> some View {
        Section("Connected") {
            LabeledContent("Account", value: account.label)
            LabeledContent("Last checked") {
                Text(account.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
            }
            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let count = connectors.upcoming.filter { $0.source == kind }.count
            if descriptor.capabilities.contains(.upcomingInterviews) {
                LabeledContent("Upcoming interviews", value: "\(count)")
            }
            HStack {
                Button("Sync Now") { Task { await connectors.sync(kind) } }
                    .disabled(connectors.syncing.contains(kind))
                Spacer()
                Button("Disconnect\u{2026}", role: .destructive) { confirmDisconnect = true }
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        Section {
            switch descriptor.auth {
            case .system:
                if kind == .icsFile {
                    Button("Import Invite\u{2026}") { isImportingInvite = true }
                } else {
                    TextField("Extra title words (optional)", text: binding("keywords"),
                              prompt: Text("e.g. debrief, pairing"))
                    actionButton("Allow Calendar Access")
                }
            case .fields(let credentialFields):
                ForEach(credentialFields, id: \.key) { field($0) }
                actionButton("Connect")
            case .oauth(_, let clientFields):
                ForEach(clientFields, id: \.key) { field($0) }
                actionButton("Sign In with Browser\u{2026}")
            }
        } header: {
            Text("Set Up")
        } footer: {
            Text(descriptor.setup)
        }
    }

    private func field(_ field: CredentialField) -> some View {
        Group {
            if field.isSecret {
                SecureField(field.label, text: binding(field.key), prompt: Text(field.isOptional ? "Optional" : "Required"))
            } else {
                TextField(field.label, text: binding(field.key),
                          prompt: Text(field.placeholder.isEmpty ? (field.isOptional ? "Optional" : "Required") : field.placeholder))
            }
        }
    }

    private func actionButton(_ title: String) -> some View {
        HStack {
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button(title) { run() }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || !requiredFieldsFilled)
        }
    }

    // MARK: - Actions

    private var requiredFieldsFilled: Bool {
        let required: [CredentialField]
        switch descriptor.auth {
        case .fields(let list): required = list.filter { !$0.isOptional }
        case .oauth(_, let list): required = list.filter { !$0.isOptional }
        case .system: required = []
        }
        return required.allSatisfy { !(fields[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func run() {
        isWorking = true
        message = nil
        Task {
            do {
                if case .oauth = descriptor.auth {
                    message = "Finish signing in in your browser\u{2026}"
                    failed = false
                    try await connectors.signIn(kind, fields: fields)
                } else {
                    try await connectors.connect(kind, fields: fields)
                }
                failed = false
                message = "Connected."
                fields = [:]
            } catch {
                failed = true
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func importInvites(_ urls: [URL]) {
        var total = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                total += try connectors.importInvite(url).count
            } catch {
                failed = true
                message = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        failed = false
        message = "Added \(total) interview\(total == 1 ? "" : "s"). They appear under Interview \u{203A} Upcoming."
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
    }

    private var privacyNote: String {
        switch descriptor.auth {
        case .system: return "Read on this Mac only."
        default: return "The key or sign-in is kept in the macOS Keychain. Interview data is read from \(descriptor.name) and kept on this Mac."
        }
    }
}
