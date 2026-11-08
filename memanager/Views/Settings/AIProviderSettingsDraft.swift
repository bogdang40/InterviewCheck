import Foundation

/// Editable copy of the provider fields, loaded once when the screen
/// appears. The provider sections write changes back to SettingsManager
/// through their bindings, so the draft is never the source of truth.
struct AIProviderSettingsDraft {
    private var editedProviders: Set<AIProviderType> = []
    var claudeAPIKey = ""
    var openAIAPIKey = ""
    var azureAPIKey = ""
    var selectedClaudeModel = ""
    var selectedOpenAIModel = ""
    var selectedClaudeQuickModel = ""
    var selectedOpenAIQuickModel = ""
    var selectedOpenAISolveReasoningEffort: OpenAIReasoningEffort = .high
    var selectedOpenAIQuickReasoningEffort: OpenAIReasoningEffort = .high
    var azureEndpoint = ""
    var azureDeploymentName = ""
    var azureAPIVersion = ""
    var azureQuickAssistDeployment = ""

    mutating func load(from settings: SettingsManager) {
        refreshCredentials(from: settings)
        selectedClaudeModel = settings.selectedModel(for: .claude)
        selectedOpenAIModel = settings.selectedModel(for: .openai)
        selectedClaudeQuickModel = settings.quickAssistModel(for: .claude)
        selectedOpenAIQuickModel = settings.quickAssistModel(for: .openai)
        selectedOpenAISolveReasoningEffort = settings.openAISolveReasoningEffort(forModel: selectedOpenAIModel)
        selectedOpenAIQuickReasoningEffort = settings.openAIQuickReasoningEffort(forModel: selectedOpenAIQuickModel)
        azureEndpoint = settings.azureEndpoint()
        azureDeploymentName = settings.azureDeploymentName()
        azureAPIVersion = settings.azureAPIVersion()
        azureQuickAssistDeployment = settings.quickAssistModel(for: .azureOpenAI)
    }

    func apiKey(for provider: AIProviderType) -> String {
        switch provider {
        case .claude: return claudeAPIKey
        case .openai: return openAIAPIKey
        case .azureOpenAI: return azureAPIKey
        }
    }

    mutating func editAPIKey(_ value: String, for provider: AIProviderType) {
        editedProviders.insert(provider)
        assignAPIKey(value, for: provider)
    }

    mutating func refreshCredentials(from settings: SettingsManager) {
        for provider in AIProviderType.allCases {
            hydrateAPIKey(settings.apiKey(for: provider), for: provider, status: settings.apiKeyStatus(for: provider))
        }
    }

    mutating func hydrateAPIKey(_ value: String, for provider: AIProviderType, status: CredentialStatus) {
        guard !editedProviders.contains(provider), status == .configured || status == .missing else { return }
        assignAPIKey(value, for: provider)
    }

    private mutating func assignAPIKey(_ value: String, for provider: AIProviderType) {
        switch provider {
        case .claude: claudeAPIKey = value
        case .openai: openAIAPIKey = value
        case .azureOpenAI: azureAPIKey = value
        }
    }
}
