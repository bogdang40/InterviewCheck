import SwiftUI

/// Edits one role. Changes save on their own a moment after typing stops.
struct RoleEditor: View {
    @ObservedObject private var store = RoleStore.shared
    @ObservedObject private var settings = DetectorSettings.shared
    @State private var draft: RoleProfile
    /// The store's version this editor last matched, to tell its own edits
    /// apart from changes made elsewhere (a background draft, an import).
    @State private var base: RoleProfile
    @State private var saveTask: Task<Void, Never>?
    @State private var isDrafting = false
    @State private var draftMessage: String?
    @State private var draftFailed = false
    @State private var isImportingJD = false
    @State private var pendingJD: String?

    init(role: RoleProfile) {
        _draft = State(initialValue: role)
        _base = State(initialValue: role)
    }

    var body: some View {
        Form {
            Section("Role") {
                TextField("Title", text: $draft.name, prompt: Text("Senior Backend Engineer"))
                TextField("Company", text: $draft.company, prompt: Text("Acme"))
                Toggle("Use for the next interview", isOn: Binding(
                    get: { store.selectedRoleID == draft.id },
                    set: { if $0 { store.selectedRoleID = draft.id } }
                ))
            }

            Section {
                TextEditor(text: $draft.jobDescription)
                    .font(.body)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if draft.jobDescription.isEmpty {
                            Text("Paste the job posting here, or import a PDF or Word file.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button {
                        isImportingJD = true
                    } label: {
                        Label("Import from File\u{2026}", systemImage: "doc.badge.plus")
                    }
                    .help("PDF, Word, RTF or text")
                    Button {
                        Task { await runDraft() }
                    } label: {
                        Label(isDrafting ? "Drafting\u{2026}" : "Draft Questions and Prompts", systemImage: "wand.and.stars")
                    }
                    .disabled(isDrafting || draft.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).count < 40)
                    if isDrafting { ProgressView().controlSize(.small) }
                    if let draftMessage {
                        Text(draftMessage).font(.callout).foregroundStyle(draftFailed ? .red : .secondary)
                    }
                }
            } header: {
                Text("Job Description")
            } footer: {
                Text("Paste the posting. Draft writes about ten interview questions and tailors the cheater prompts to this job.")
            }

            Section {
                ForEach($draft.plannedQuestions) { $question in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Question", text: $question.text, prompt: Text("Type a question"), axis: .vertical)
                            .labelsHidden()
                        if !question.strongAnswer.isEmpty || question.family != nil {
                            Text([question.family, question.strongAnswer.isEmpty ? nil : "Strong answer: \(question.strongAnswer)"]
                                    .compactMap { $0 }.joined(separator: " \u{00B7} "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Delete Question", role: .destructive) {
                            draft.plannedQuestions.removeAll { $0.id == question.id }
                        }
                    }
                }
                .onDelete { draft.plannedQuestions.remove(atOffsets: $0) }
                .onMove { draft.plannedQuestions.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Question") {
                    draft.plannedQuestions.append(PlannedQuestion(text: "", family: nil, strongAnswer: ""))
                }
            } header: {
                Text("Planned Questions")
            } footer: {
                Text("During the interview, click one when you ask it. Questions that ask for details of the candidate's own past work are the hardest to answer from an AI tool.")
            }

            Section {
                ForEach($draft.cheaterPrompts) { $prompt in
                    DisclosureGroup {
                        if prompt.id == CheaterPromptLibrary.copilotID {
                            Text(prompt.instructions).font(.callout).foregroundStyle(.secondary)
                        } else {
                            TextEditor(text: $prompt.instructions)
                                .frame(minHeight: 90)
                                .scrollContentBackground(.hidden)
                        }
                    } label: {
                        Toggle(prompt.name, isOn: $prompt.isEnabled)
                    }
                }
                Button("Restore Default Prompts") { draft.cheaterPrompts = CheaterPromptLibrary.defaults }
            } header: {
                Text("Cheater Prompts")
            } footer: {
                Text("Each enabled prompt runs on every AI in Settings \u{203A} Detector, so you see what different cheating tools would show the candidate.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.displayTitle)
        .onChange(of: draft) { _, newValue in scheduleSave(newValue) }
        .fileImporter(isPresented: $isImportingJD, allowedContentTypes: DocumentText.contentTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try DocumentText.read(url)
                if draft.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.jobDescription = text
                } else {
                    pendingJD = text
                }
                draftFailed = false
                draftMessage = nil
            } catch {
                draftFailed = true
                draftMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Replace the job description?",
                            isPresented: Binding(get: { pendingJD != nil }, set: { if !$0 { pendingJD = nil } })) {
            Button("Replace") {
                if let pendingJD { draft.jobDescription = pendingJD }
                pendingJD = nil
            }
        } message: {
            Text("The text from the file replaces what is there now.")
        }
        .onDisappear { saveNow() }
        .onChange(of: store.role(id: draft.id)) { _, latest in
            guard let latest else { return }
            let merged = RoleEditMerge.merge(local: draft, base: base, latest: latest)
            base = latest
            if !RoleEditMerge.sameContent(merged, draft) { draft = merged }
        }
    }

    private func scheduleSave(_ role: RoleProfile) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            store.save(role)
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard let stored = store.role(id: draft.id) else { return }
        let merged = RoleEditMerge.merge(local: draft, base: base, latest: stored)
        if !RoleEditMerge.sameContent(merged, stored) { store.save(merged) }
    }

    private func runDraft() async {
        guard let entry = settings.usableJudge() ?? settings.usableLineup().first else {
            draftFailed = true
            draftMessage = "Add a Claude or OpenAI key in Settings first."
            return
        }
        isDrafting = true
        draftMessage = nil
        defer { isDrafting = false }
        do {
            let client = try DetectorTextClientFactory.make(provider: entry.provider, model: entry.model)
            let result = try await RoleDraftService.draft(roleTitle: draft.displayTitle,
                                                          jobDescription: draft.jobDescription, using: client)
            draft = RoleDraftService.apply(result, to: draft)
            draftFailed = false
            draftMessage = "Drafted \(result.questions.count) questions and tailored the prompts."
        } catch {
            draftFailed = true
            draftMessage = "Draft failed: \(error.localizedDescription)"
        }
    }
}
