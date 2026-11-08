import Foundation

enum AIProviderType: String, CaseIterable, Codable {
    case claude = "Claude"
    case openai = "OpenAI"
    case azureOpenAI = "AzureOpenAI"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .azureOpenAI: return "Azure OpenAI"
        }
    }
}

struct AzureOpenAIConfig {
    let endpoint: String      // e.g., "https://myresource.openai.azure.com"
    let deploymentName: String // e.g., "gpt-4o"
    let apiVersion: String    // e.g., "2024-02-01"
}

final class AIProviderFactory {
    static func create(
        type: AIProviderType,
        apiKey: String,
        model: String? = nil,
        quickAssistModel: String? = nil,
        reasoningSettings: OpenAIReasoningSettings = .default,
        azureConfig: AzureOpenAIConfig? = nil
    ) throws -> AIProvider {
        switch type {
        case .claude:
            return ClaudeProvider(
                apiKey: apiKey,
                model: model ?? "claude-sonnet-5",
                quickAssistModel: quickAssistModel
            )
        case .openai:
            return OpenAIProvider(
                apiKey: apiKey,
                model: model ?? "gpt-5.2",
                quickAssistModel: quickAssistModel,
                reasoningSettings: reasoningSettings
            )
        case .azureOpenAI:
            guard let config = azureConfig else {
                throw ProviderConfigurationError.missingAzureConfig
            }
            return AzureOpenAIProvider(apiKey: apiKey, config: config, quickAssistModel: quickAssistModel)
        }
    }
}
