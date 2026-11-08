import SwiftUI

/// Claude: key, the Solve and Quick Assist models, and their tests.
struct ClaudeProviderSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var draft: AIProviderSettingsDraft
    let isActive: Bool

    @State private var solveTest = APITestState()
    @State private var quickTest = APITestState()

    var body: some View {
        SettingsSection("Claude", trailing: { ProviderActiveBadge(isActive: isActive) }) {
            ProviderCredentialRow(provider: .claude, draft: $draft)

            SettingsModelRow(
                title: "Solve model",
                helper: "Used for Solve and Design.",
                curated: SettingsManager.availableModels(for: .claude),
                model: $draft.selectedClaudeModel,
                placeholder: "claude-sonnet-5"
            )
            .onChange(of: draft.selectedClaudeModel) { _, newValue in
                settings.setSelectedModel(newValue, for: .claude)
            }

            SettingsModelRow(
                title: "Quick model",
                helper: "Used for Quick Assist. Availability and response time depend on the selected model and account.",
                curated: SettingsManager.availableQuickAssistModels(for: .claude),
                model: $draft.selectedClaudeQuickModel,
                placeholder: "claude-haiku-4-5"
            )
            .onChange(of: draft.selectedClaudeQuickModel) { _, newValue in
                settings.setQuickAssistModel(newValue, for: .claude)
            }

            APITestRow(tests: [
                APITestSlot(id: "claude-solve", label: "Test solve model", state: $solveTest, isEnabled: !draft.claudeAPIKey.isEmpty && !draft.selectedClaudeModel.isEmpty) {
                    await APITester.testClaude(apiKey: draft.claudeAPIKey, model: draft.selectedClaudeModel)
                },
                APITestSlot(id: "claude-quick", label: "Test quick model", state: $quickTest, isEnabled: !draft.claudeAPIKey.isEmpty && !draft.selectedClaudeQuickModel.isEmpty) {
                    await APITester.testClaude(apiKey: draft.claudeAPIKey, model: draft.selectedClaudeQuickModel)
                }
            ])
        }
        .onChange(of: [draft.claudeAPIKey, draft.selectedClaudeModel, draft.selectedClaudeQuickModel]) { _, _ in
            solveTest.invalidate()
            quickTest.invalidate()
        }
    }
}
