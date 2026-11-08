import Foundation

struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [ClaudeMessage]
}

struct ClaudeMessage: Encodable {
    let role: String
    let content: [ClaudeContentBlock]
}

struct ClaudeContentBlock: Encodable {
    let type: String
    var text: String?
    var source: ClaudeImageSource?
}

struct ClaudeImageSource: Encodable {
    let type: String
    let media_type: String
    let data: String
}

struct ClaudeResponse: Decodable {
    let content: [ClaudeResponseContent]
}

struct ClaudeResponseContent: Decodable {
    let type: String
    let text: String?
}

// MARK: - Streaming Request/Response Models

struct ClaudeStreamRequest: Encodable {
    let model: String
    let max_tokens: Int
    let stream: Bool
    let system: String
    let messages: [ClaudeMessage]
}

struct ClaudeStreamEvent: Decodable {
    let type: String
    let delta: ClaudeStreamDelta?
}

struct ClaudeStreamDelta: Decodable {
    let type: String
    let text: String?
}
