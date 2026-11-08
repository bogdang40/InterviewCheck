import SwiftUI

/// OpenAI: key, the two models with their reasoning efforts, the natural
/// language guard, and connection tests.
struct OpenAIProviderSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var draft: AIProviderSettingsDraft
    let isActive: Bool

    @State private var solveTest = APITestState()
    @State private var quickTest = APITestState()

    private var displayModeItems: [SegmentItem<OpenAIQuickAssistDisplayMode>] {
        [
            SegmentItem(id: .response, title: "Raw"),
            SegmentItem(id: .guarded, title: "Guarded")
        ]
    }

    private var guardFooter: String {
        settings.openAIVoiceGuardEnabled
            ? "OpenAI uses the selected model for each path. The provider shortcut still cycles providers."
            : "The natural language guard is off, so Quick Assist always shows raw OpenAI output."
    }

    var body: some View {
        SettingsSection("OpenAI", footer: guardFooter, trailing: { ProviderActiveBadge(isActive: isActive) }) {
            ProviderCredentialRow(provider: .openai, draft: $draft)

            SettingsModelRow(
                title: "Solve model",
                helper: "Used for Solve and Design.",
                curated: SettingsManager.availableModels(for: .openai),
                model: $draft.selectedOpenAIModel,
                placeholder: "gpt-5.2"
            )
            .onChange(of: draft.selectedOpenAIModel) { _, newValue in
                settings.setSelectedModel(newValue, for: .openai)
                draft.selectedOpenAISolveReasoningEffort = settings.openAISolveReasoningEffort(forModel: newValue)
            }

            OpenAIReasoningEffortPickerRow(
                title: "Solve effort",
                model: draft.selectedOpenAIModel,
                selection: $draft.selectedOpenAISolveReasoningEffort
            ) { newValue in
                settings.setOpenAISolveReasoningEffort(newValue, forModel: draft.selectedOpenAIModel)
            }

            SettingsModelRow(
                title: "Quick model",
                helper: "Used for Quick Assist.",
                curated: SettingsManager.availableQuickAssistModels(for: .openai),
                model: $draft.selectedOpenAIQuickModel,
                placeholder: "gpt-5.2"
            )
            .onChange(of: draft.selectedOpenAIQuickModel) { _, newValue in
                settings.setQuickAssistModel(newValue, for: .openai)
                draft.selectedOpenAIQuickReasoningEffort = settings.openAIQuickReasoningEffort(forModel: newValue)
            }

            OpenAIReasoningEffortPickerRow(
                title: "Quick effort",
                model: draft.selectedOpenAIQuickModel,
                selection: $draft.selectedOpenAIQuickReasoningEffort
            ) { newValue in
                settings.setOpenAIQuickReasoningEffort(newValue, forModel: draft.selectedOpenAIQuickModel)
            }

            SettingsToggleRow(
                title: "Natural language guard",
                helper: "Rewrites Quick Assist output into spoken language before it is shown.",
                isOn: $settings.openAIVoiceGuardEnabled
            )

            SettingsRow(title: "Quick Assist view", helper: "Which version of the answer the canvas shows.") {
                SegmentStrip(items: displayModeItems, selection: $settings.openAIQuickAssistDisplayMode)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!settings.openAIVoiceGuardEnabled)
                    .opacity(settings.openAIVoiceGuardEnabled ? 1 : 0.45)
            }

            APITestRow(tests: [
                APITestSlot(id: "openai-solve", label: "Test solve model", state: $solveTest, isEnabled: !draft.openAIAPIKey.isEmpty && !draft.selectedOpenAIModel.isEmpty) {
                    await APITester.testOpenAI(
                        apiKey: draft.openAIAPIKey,
                        model: draft.selectedOpenAIModel,
                        reasoningEffort: draft.selectedOpenAISolveReasoningEffort
                    )
                },
                APITestSlot(id: "openai-quick", label: "Test quick model", state: $quickTest, isEnabled: !draft.openAIAPIKey.isEmpty && !draft.selectedOpenAIQuickModel.isEmpty) {
                    await APITester.testOpenAI(
                        apiKey: draft.openAIAPIKey,
                        model: draft.selectedOpenAIQuickModel,
                        reasoningEffort: draft.selectedOpenAIQuickReasoningEffort
                    )
                }
            ])
        }
        .onChange(of: [draft.openAIAPIKey, draft.selectedOpenAIModel, draft.selectedOpenAIQuickModel]) { _, _ in invalidateTests() }
        .onChange(of: draft.selectedOpenAISolveReasoningEffort) { _, _ in solveTest.invalidate() }
        .onChange(of: draft.selectedOpenAIQuickReasoningEffort) { _, _ in quickTest.invalidate() }
    }

    private func invalidateTests() {
        solveTest.invalidate()
        quickTest.invalidate()
    }
}
