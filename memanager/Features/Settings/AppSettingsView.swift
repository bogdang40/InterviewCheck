import SwiftUI

/// The Settings window (Cmd+,).
struct AppSettingsView: View {
    var body: some View {
        TabView {
            KeysSettingsTab()
                .tabItem { Label("Keys", systemImage: "key") }
            DetectorSettingsTab()
                .tabItem { Label("Detector", systemImage: "checkmark.shield") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            LicenseSettingsTab()
                .tabItem { Label("License", systemImage: "person.badge.key") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 560)
    }
}

/// API keys. Keys live in the Keychain; fields stay empty and show only
/// whether a key is saved.
struct KeysSettingsTab: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var deepgram = ""
    @State private var anthropic = ""
    @State private var openAI = ""
    @State private var azureKey = ""
    @State private var azureEndpoint = SettingsManager.shared.azureEndpoint()
    @State private var azureDeployment = SettingsManager.shared.azureDeploymentName()
    @State private var hasDeepgram = VoiceSignatureStore.shared.hasDeepgramApiKey
    @State private var savedNote: String?

    var body: some View {
        Form {
            Section {
                keyRow("Deepgram", text: $deepgram, saved: hasDeepgram) {
                    VoiceSignatureStore.shared.saveDeepgramApiKey($0)
                    hasDeepgram = true
                } remove: {
                    VoiceSignatureStore.shared.deleteDeepgramApiKey()
                    hasDeepgram = false
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Deepgram transcribes both sides of the call with word timings. Required.")
            }

            Section {
                keyRow("Anthropic (Claude)", text: $anthropic, saved: !settings.apiKey(for: .claude).isEmpty) {
                    settings.setApiKey($0, for: .claude)
                } remove: { settings.setApiKey("", for: .claude) }
                keyRow("OpenAI", text: $openAI, saved: !settings.apiKey(for: .openai).isEmpty) {
                    settings.setApiKey($0, for: .openai)
                } remove: { settings.setApiKey("", for: .openai) }
            } header: {
                Text("AI Providers")
            } footer: {
                Text("Used for the AI answers, the AI review and drafting questions. An OpenAI key also enables meaning comparison.")
            }

            Section("Azure OpenAI (optional)") {
                TextField("Endpoint", text: $azureEndpoint, prompt: Text(verbatim: "https://your-resource.openai.azure.com"))
                    .onSubmit { settings.setAzureEndpoint(azureEndpoint) }
                TextField("Deployment", text: $azureDeployment, prompt: Text("gpt-4o"))
                    .onSubmit { settings.setAzureDeploymentName(azureDeployment) }
                keyRow("Azure key", text: $azureKey, saved: !settings.apiKey(for: .azureOpenAI).isEmpty) {
                    settings.setAzureEndpoint(azureEndpoint)
                    settings.setAzureDeploymentName(azureDeployment)
                    settings.setApiKey($0, for: .azureOpenAI)
                } remove: { settings.setApiKey("", for: .azureOpenAI) }
            }

            if let savedNote {
                Text(savedNote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func keyRow(_ title: String, text: Binding<String>, saved: Bool,
                        save: @escaping (String) -> Void, remove: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                SecureField(saved ? "Saved \u{2022}\u{2022}\u{2022}\u{2022}" : "Paste key", text: text)
                    .frame(minWidth: 220)
                    .onSubmit { commit(text, save: save, title: title) }
                Button("Save") { commit(text, save: save, title: title) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved {
                    Button("Remove", role: .destructive) { remove(); savedNote = "\(title) key removed." }
                }
            }
        }
    }

    private func commit(_ text: Binding<String>, save: (String) -> Void, title: String) {
        let key = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        save(key)
        text.wrappedValue = ""
        savedNote = "\(title) key saved to the Keychain."
    }
}

/// Which AIs answer each question, the AI review, meaning comparison, notice.
struct DetectorSettingsTab: View {
    @ObservedObject private var settings = DetectorSettings.shared
    @ObservedObject private var providers = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                ForEach($settings.lineup) { $entry in
                    HStack {
                        Toggle("", isOn: $entry.isEnabled).labelsHidden()
                        Picker("", selection: $entry.provider) {
                            ForEach(AIProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        ModelField(provider: entry.provider, model: $entry.model)
                        if providers.apiKey(for: entry.provider).isEmpty { Tag(text: "No key", color: .orange) }
                        Spacer()
                        Button(role: .destructive) { settings.lineup.removeAll { $0.id == entry.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add AI") { settings.lineup.append(LineupEntry(provider: .openai, model: "gpt-4o")) }
            } header: {
                Text("AI answers to compare against")
            } footer: {
                Text("Each row answers every question with each enabled cheater prompt, up to 6 answers per question.")
            }

            Section {
                Toggle("Review each answer with AI", isOn: $settings.judgeEnabled)
                HStack {
                    Picker("Model", selection: $settings.judge.provider) {
                        ForEach(AIProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(width: 220)
                    ModelField(provider: settings.judge.provider, model: $settings.judge.model)
                }
                .disabled(!settings.judgeEnabled)
                Toggle("Compare meaning, not just wording (OpenAI embeddings)", isOn: $settings.useEmbeddings)
            } header: {
                Text("Review")
            } footer: {
                Text("The review adds evidence and two follow-up questions to each score.")
            }

            Section("Notice for candidates") {
                TextEditor(text: $settings.consentNotice)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            }

            Button("Restore Detector Defaults") { settings.restoreDefaults() }
        }
        .formStyle(.grouped)
    }
}

/// A model picker for known providers; a text field for Azure deployments.
struct ModelField: View {
    let provider: AIProviderType
    @Binding var model: String

    private var options: [String] {
        let all = SettingsManager.availableModels(for: provider) + SettingsManager.availableQuickAssistModels(for: provider)
        var unique = all.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !model.isEmpty, !unique.contains(model) { unique.append(model) }
        return unique
    }

    var body: some View {
        if provider == .azureOpenAI || options.isEmpty {
            TextField("Deployment", text: $model).frame(width: 200)
        } else {
            Picker("", selection: $model) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}
