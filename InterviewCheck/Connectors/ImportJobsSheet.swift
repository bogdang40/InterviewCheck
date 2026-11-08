import InterviewCheckConnectors
import SwiftUI

/// Roles › Import from ATS: pick open jobs to turn into roles.
struct ImportJobsSheet: View {
    @ObservedObject private var connectors = ConnectorManager.shared
    @ObservedObject private var roles = RoleStore.shared
    @Environment(\.dismiss) private var dismiss
    var onImported: (RoleProfile?) -> Void = { _ in }
    @State private var source: ConnectorKind?
    @State private var jobs: [ExternalJob] = []
    @State private var picked: Set<String> = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var error: String?

    private var sources: [ConnectorKind] { connectors.jobSources }

    private var shown: [ExternalJob] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? jobs : jobs.filter { $0.title.lowercased().contains(query) }
    }

    private func isImported(_ job: ExternalJob) -> Bool {
        guard let source else { return false }
        return roles.roles.contains { $0.externalJobKey == "\(source.rawValue):\(job.externalID)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Roles from Your ATS").font(.title2.weight(.semibold))
            if sources.isEmpty {
                ContentUnavailableView {
                    Label("No ATS Connected", systemImage: "briefcase")
                } description: {
                    Text("Connect Greenhouse, Lever, Ashby, Workable or another ATS in Connections to import its open jobs.")
                } actions: {
                    Button("Open Connections") {
                        AppNavigation.shared.show(.connections)
                        dismiss()
                    }
                }
                .frame(minHeight: 220)
            } else {
                Picker("From", selection: $source) {
                    ForEach(sources) { Text($0.descriptor.name).tag(Optional($0)) }
                }
                .frame(maxWidth: 320)
                TextField("Search jobs", text: $search)
                    .textFieldStyle(.roundedBorder)
                List(shown, id: \.externalID) { job in
                    Toggle(isOn: Binding(get: { picked.contains(job.externalID) || isImported(job) },
                                         set: { on in if on { picked.insert(job.externalID) } else { picked.remove(job.externalID) } })) {
                        HStack {
                            Text(job.title)
                            if isImported(job) { Tag(text: "Imported", color: .green) }
                        }
                    }
                    .disabled(isImported(job))
                }
                .frame(minHeight: 260)
                .overlay {
                    if isLoading { ProgressView("Loading open jobs\u{2026}") }
                    else if jobs.isEmpty, error == nil { Text("No open jobs.").foregroundStyle(.secondary) }
                }
                Text("Each job becomes a role with its job description; questions and AI-tool prompts are drafted in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isImporting { ProgressView().controlSize(.small) }
                Button(picked.isEmpty ? "Import" : "Import \(picked.count)") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || isImporting)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { if source == nil { source = sources.first } }
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source else { return }
        isLoading = true
        error = nil
        picked = []
        defer { isLoading = false }
        do {
            jobs = try await connectors.openJobs(source)
        } catch {
            jobs = []
            self.error = error.localizedDescription
        }
    }

    private func runImport() {
        guard let source else { return }
        let chosen = jobs.filter { picked.contains($0.externalID) }
        isImporting = true
        Task {
            let imported = await connectors.importJobs(chosen, from: source)
            isImporting = false
            onImported(imported.first)
            dismiss()
        }
    }
}
