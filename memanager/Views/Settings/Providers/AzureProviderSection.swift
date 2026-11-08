import SwiftUI

/// Azure OpenAI: key, endpoint, deployments, API version, an explicit save,
/// and connection tests for each deployment.
struct AzureProviderSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var draft: AIProviderSettingsDraft
    let isActive: Bool

    @State private var mainTest = APITestState()
    @State private var quickTest = APITestState()

    private var endpointLooksDecorated: Bool {
        draft.azureEndpoint.contains("/openai/") || draft.azureEndpoint.contains("?")
    }

    private var hasQuickDeployment: Bool {
        !draft.azureQuickAssistDeployment.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        SettingsSection("Azure OpenAI", trailing: { ProviderActiveBadge(isActive: isActive) }) {
            ProviderCredentialRow(provider: .azureOpenAI, draft: $draft)

            SettingsTextRow(
                title: "Endpoint",
                helper: "The resource base URL only. Paths and queries are removed.",
                placeholder: "https://myresource.openai.azure.com",
                text: $draft.azureEndpoint,
                monospaced: true,
                onSubmit: commitEndpoint
            ) {
                if endpointLooksDecorated {
                    ToneBadge(text: "Will be trimmed", tone: .warning, systemImage: "scissors")
                }
            }
            .onChange(of: draft.azureEndpoint) { _, newValue in
                settings.setAzureEndpoint(newValue)
            }

            SettingsTextRow(
                title: "Deployment",
                helper: "Used for Solve and Design.",
                placeholder: "gpt-4o",
                text: $draft.azureDeploymentName,
                monospaced: true,
                onSubmit: { settings.setAzureDeploymentName(draft.azureDeploymentName) }
            )
            .onChange(of: draft.azureDeploymentName) { _, newValue in
                settings.setAzureDeploymentName(newValue)
            }

            SettingsTextRow(
                title: "API version",
                placeholder: "2024-02-01",
                text: $draft.azureAPIVersion,
                monospaced: true,
                onSubmit: { settings.setAzureAPIVersion(draft.azureAPIVersion) }
            )
            .onChange(of: draft.azureAPIVersion) { _, newValue in
                settings.setAzureAPIVersion(newValue)
            }

            SettingsTextRow(
                title: "Quick Assist deployment",
                helper: "Optional. Uses this deployment for Quick Assist when provided.",
                placeholder: "gpt-4o-mini",
                text: $draft.azureQuickAssistDeployment,
                monospaced: true
            )
            .onChange(of: draft.azureQuickAssistDeployment) { _, newValue in
                settings.setQuickAssistModel(newValue, for: .azureOpenAI)
            }

            SettingsRow(title: "Save", helper: "Writes every Azure field and normalises the endpoint.") {
                Button("Save Azure settings", action: saveAll)
                    .buttonStyle(.overlay(.primary, size: .small))
            }

            APITestRow(tests: tests)
        }
        .onChange(of: [draft.azureAPIKey, draft.azureEndpoint, draft.azureDeploymentName, draft.azureAPIVersion, draft.azureQuickAssistDeployment]) { _, _ in
            mainTest.invalidate()
            quickTest.invalidate()
        }
    }

    private var tests: [APITestSlot] {
        var slots = [
            APITestSlot(id: "azure-main", label: "Test main deployment", state: $mainTest, isEnabled: !draft.azureAPIKey.isEmpty && !draft.azureEndpoint.isEmpty && !draft.azureDeploymentName.isEmpty) {
                await APITester.testAzureOpenAI(
                    apiKey: draft.azureAPIKey,
                    endpoint: draft.azureEndpoint,
                    deployment: draft.azureDeploymentName,
                    apiVersion: draft.azureAPIVersion
                )
            }
        ]
        if hasQuickDeployment {
            slots.append(APITestSlot(id: "azure-quick", label: "Test quick deployment", state: $quickTest, isEnabled: !draft.azureAPIKey.isEmpty && !draft.azureEndpoint.isEmpty) {
                await APITester.testAzureOpenAI(
                    apiKey: draft.azureAPIKey,
                    endpoint: draft.azureEndpoint,
                    deployment: draft.azureQuickAssistDeployment,
                    apiVersion: draft.azureAPIVersion
                )
            })
        }
        return slots
    }

    private func commitEndpoint() {
        settings.setAzureEndpoint(draft.azureEndpoint)
        draft.azureEndpoint = settings.azureEndpoint()
    }

    private func saveAll() {
        settings.setApiKey(draft.azureAPIKey, for: .azureOpenAI)
        settings.setAzureEndpoint(draft.azureEndpoint)
        settings.setAzureDeploymentName(draft.azureDeploymentName)
        settings.setAzureAPIVersion(draft.azureAPIVersion)
        draft.azureEndpoint = settings.azureEndpoint()
    }
}
