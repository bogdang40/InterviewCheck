import Foundation

/// The AI services the detector can call.
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

struct AzureOpenAIConfig: Equatable {
    let endpoint: String      // e.g. "https://myresource.openai.azure.com"
    let deploymentName: String // e.g. "gpt-4o"
    let apiVersion: String    // e.g. "2024-02-01"
}
