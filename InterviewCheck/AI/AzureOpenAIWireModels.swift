import Foundation

struct AzureOpenAIRequest: Encodable {
    let max_completion_tokens: Int?
    let messages: [AzureOpenAIMessage]
}

struct AzureOpenAIMessage: Encodable {
    let role: String
    let content: [AzureOpenAIContentBlock]
}

struct AzureOpenAIContentBlock: Encodable {
    let type: String
    var text: String?
    var image_url: AzureOpenAIImageURL?
}

struct AzureOpenAIImageURL: Encodable {
    let url: String
}

struct AzureOpenAIResponse: Decodable {
    let choices: [AzureOpenAIChoice]
}

struct AzureOpenAIChoice: Decodable {
    let message: AzureOpenAIMessageContent
}

struct AzureOpenAIMessageContent: Decodable {
    let content: String?
}

// MARK: - Streaming Request/Response Models

struct AzureOpenAIStreamRequest: Encodable {
    let max_completion_tokens: Int?
    let stream: Bool
    let messages: [AzureOpenAIMessage]
}

struct AzureOpenAIStreamEvent: Decodable {
    let choices: [AzureOpenAIStreamChoice]
}

struct AzureOpenAIStreamChoice: Decodable {
    let delta: AzureOpenAIStreamDelta?
}

struct AzureOpenAIStreamDelta: Decodable {
    let content: String?
}
