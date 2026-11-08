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

// MARK: - Responses API Request Models

struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIResponsesInputMessage]
    let stream: Bool?
    let reasoning: OpenAIResponsesReasoning?
    let max_output_tokens: Int?
}

struct OpenAIResponsesInputMessage: Encodable {
    let role: String
    let content: [OpenAIResponsesInputContent]
}

struct OpenAIResponsesInputContent: Encodable {
    let type: String
    var text: String?
    var image_url: String?
}

struct OpenAIResponsesReasoning: Encodable {
    let effort: OpenAIReasoningEffort
}

struct OpenAIResponsesStreamingEventResult {
    enum Kind {
        case outputTextDelta
        case outputTextDone
        case other
    }

    let eventType: String?
    let kind: Kind
    let visibleText: String?
    let itemKey: String?
    let didComplete: Bool
}
