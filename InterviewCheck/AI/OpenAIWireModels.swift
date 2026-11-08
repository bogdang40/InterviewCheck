import Foundation

struct OpenAIRequest: Encodable {
    let model: String
    let max_completion_tokens: Int?
    let messages: [OpenAIMessage]
}

struct OpenAIMessage: Encodable {
    let role: String
    let content: [OpenAIContentBlock]
}

struct OpenAIContentBlock: Encodable {
    let type: String
    var text: String?
    var image_url: OpenAIImageURL?
}

struct OpenAIImageURL: Encodable {
    let url: String
}

struct OpenAIResponse: Decodable {
    let choices: [OpenAIChoice]
}

struct OpenAIChoice: Decodable {
    let message: OpenAIMessageContent
}

struct OpenAIMessageContent: Decodable {
    let content: String?
}

struct OpenAIStreamRequest: Encodable {
    let model: String
    let max_completion_tokens: Int?
    let stream: Bool
    let messages: [OpenAIMessage]
}
