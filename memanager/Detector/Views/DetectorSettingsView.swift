import SwiftUI

/// Settings for the cheating detector: which AIs answer each question, the
/// AI review, meaning comparison, and the notice read to candidates.
struct DetectorSettingsView: View {
    @ObservedObject var settings = DetectorSettings.shared
    @ObservedObject var providerSettings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            SettingsSection("AI answers to compare against",
                            footer: "Each row answers every question with each enabled cheater prompt (at most 6 answers per question). Rows without a key in Providers are skipped.") {
                ForEach($settings.lineup) { $entry in
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Toggle("", isOn: $entry.isEnabled).toggleStyle(.checkbox).labelsHidden()
                        Picker("", selection: $entry.provider) {
                            ForEach(AIProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        modelPicker(provider: entry.provider, model: $entry.model)
                        if providerSettings.apiKey(for: entry.provider).isEmpty {
                            ToneBadge(text: "No key", tone: .warning)
                        }
                        Spacer(minLength: 0)
                        Button { settings.lineup.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.overlayIcon(size: 26))
                            .accessibilityLabel("Remove \(entry.model)")
                    }
                }
                Button("Add AI", systemImage: "plus") {
                    settings.lineup.append(LineupEntry(provider: .openai, model: "gpt-4o"))
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }

            SettingsSection("AI review", footer: "After each answer, one model reviews the timing, wording and AI answers, adds evidence and suggests two follow-up questions.") {
                SettingsRow(title: "Review each answer") {
                    Toggle("", isOn: $settings.judgeEnabled).toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Picker("", selection: $settings.judge.provider) {
                        ForEach(AIProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    modelPicker(provider: settings.judge.provider, model: $settings.judge.model)
                    Spacer(minLength: 0)
                }
                .disabled(!settings.judgeEnabled)
            }

            SettingsSection("Meaning comparison") {
                SettingsRow(title: "Compare meaning, not just wording",
                            helper: "Uses OpenAI embeddings (text-embedding-3-small). Needs an OpenAI key.") {
                    Toggle("", isOn: $settings.useEmbeddings).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsSection("Notice for candidates", footer: "Shown before each interview. Recording laws differ by place.") {
                OverlayTextEditor(placeholder: "What you tell the candidate", text: $settings.consentNotice, height: 90)
            }

            Button("Restore detector defaults") { settings.restoreDefaults() }
                .buttonStyle(.overlay(.ghost, size: .small))
        }
    }

    @ViewBuilder
    private func modelPicker(provider: AIProviderType, model: Binding<String>) -> some View {
        let options = SettingsManager.availableModels(for: provider) + SettingsManager.availableQuickAssistModels(for: provider)
        let unique = options.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if provider == .azureOpenAI || unique.isEmpty {
            OverlayTextInput(placeholder: "Deployment or model", text: model).frame(width: 200)
        } else {
            Picker("", selection: model) {
                ForEach(unique + (unique.contains(model.wrappedValue) ? [] : [model.wrappedValue]), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}
