import SwiftUI

/// A role's interview kit: the job description, drafted questions, and the
/// cheater prompts that imitate a candidate's AI tool.
struct RoleKitSection: View {
    @ObservedObject var roles = RoleStore.shared
    @ObservedObject var settings = DetectorSettings.shared
    let workspace: JobWorkspace
    @State private var draft: RoleProfile?
    @State private var isDrafting = false
    @State private var message: (tone: OverlayTone, text: String)?

    private var profile: RoleProfile { draft ?? roles.profile(for: workspace.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            if let message {
                ToneBanner(tone: message.tone, message: message.text, onDismiss: { self.message = nil })
            }
            LabeledField("Job description", hint: "Paste the posting. Draft uses it for questions and for the prompts below.") {
                OverlayTextEditor(placeholder: "Paste the job description",
                                  text: binding(\.jobDescription), height: 160)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button(isDrafting ? "Drafting\u{2026}" : "Draft questions and prompts", systemImage: "wand.and.stars") {
                    Task { await runDraft() }
                }
                .buttonStyle(.overlay(.primary))
                .disabled(isDrafting || profile.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).count < 40)
                if isDrafting { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if draft != nil {
                    Button("Save") { save() }.buttonStyle(.overlay(.secondary, size: .small))
                }
            }

            plannedQuestions
            cheaterPrompts
        }
        .onChange(of: workspace.id) { _, _ in draft = nil; message = nil }
    }

    private var plannedQuestions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                FieldLabel(text: "Planned questions (\(profile.plannedQuestions.count))")
                Spacer(minLength: 0)
                Button("Add", systemImage: "plus") {
                    edit { $0.plannedQuestions.append(PlannedQuestion(text: "", family: nil, strongAnswer: "")) }
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            if profile.plannedQuestions.isEmpty {
                Text("None yet. Draft them from the job description, or add your own.")
                    .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
            }
            ForEach(Array(profile.plannedQuestions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        ToneBadge(text: "\(index + 1)", monospaced: true)
                        OverlayTextInput(placeholder: "Question", text: questionBinding(index, \.text))
                        Button { edit { $0.plannedQuestions.remove(at: index) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.overlayIcon(size: 26))
                            .accessibilityLabel("Remove question \(index + 1)")
                    }
                    if !question.strongAnswer.isEmpty || question.family != nil {
                        Text([question.family, question.strongAnswer.isEmpty ? nil : "Strong answer: \(question.strongAnswer)"]
                                .compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var cheaterPrompts: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: "Cheater prompts")
            Text("Each enabled prompt runs on every AI in your lineup, so you see what different cheating tools would show the candidate.")
                .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(profile.cheaterPrompts.enumerated()), id: \.element.id) { index, prompt in
                DisclosureGroup {
                    if prompt.id == CheaterPromptLibrary.copilotID {
                        Text(prompt.instructions)
                            .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                    } else {
                        OverlayTextEditor(placeholder: "Instructions", text: promptBinding(index, \.instructions), height: 110)
                    }
                } label: {
                    Toggle(isOn: promptBinding(index, \.isEnabled)) {
                        Text(prompt.name).font(OverlayType.heading).foregroundStyle(OverlayPalette.textPrimary)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(DesignTokens.Spacing.sm)
                .overlayCard(.base)
            }
            Button("Restore default prompts") { edit { $0.cheaterPrompts = CheaterPromptLibrary.defaults } }
                .buttonStyle(.overlay(.ghost, size: .small))
        }
    }

    // MARK: - Editing

    private func edit(_ change: (inout RoleProfile) -> Void) {
        var updated = profile
        change(&updated)
        draft = updated
    }

    private func binding<T>(_ keyPath: WritableKeyPath<RoleProfile, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: keyPath] }, set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    private func questionBinding(_ index: Int, _ keyPath: WritableKeyPath<PlannedQuestion, String>) -> Binding<String> {
        Binding(get: { profile.plannedQuestions.indices.contains(index) ? profile.plannedQuestions[index][keyPath: keyPath] : "" },
                set: { value in edit { if $0.plannedQuestions.indices.contains(index) { $0.plannedQuestions[index][keyPath: keyPath] = value } } })
    }

    private func promptBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<CheaterPrompt, T>) -> Binding<T> {
        Binding(get: { profile.cheaterPrompts[index][keyPath: keyPath] },
                set: { value in edit { $0.cheaterPrompts[index][keyPath: keyPath] = value } })
    }

    private func save() {
        guard var updated = draft else { return }
        updated.plannedQuestions.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        roles.save(updated, workspace: workspace)
        draft = nil
        message = (.success, "Saved.")
    }

    private func runDraft() async {
        guard let entry = settings.usableJudge() ?? settings.usableLineup().first else {
            message = (.warning, "Add a Claude or OpenAI key in Settings to draft.")
            return
        }
        isDrafting = true
        defer { isDrafting = false }
        do {
            let client = try DetectorTextClientFactory.make(provider: entry.provider, model: entry.model)
            let result = try await RoleDraftService.draft(roleTitle: workspace.displayTitle,
                                                          jobDescription: profile.jobDescription, using: client)
            draft = RoleDraftService.apply(result, to: profile)
            save()
            message = (.success, "Drafted \(result.questions.count) questions and tailored the prompts. Edit anything, then Save.")
        } catch {
            message = (.critical, "Draft failed: \(error.localizedDescription)")
        }
    }
}
