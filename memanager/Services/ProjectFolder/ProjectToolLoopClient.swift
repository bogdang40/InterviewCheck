import Foundation

protocol ProjectToolLoopClient: AnyObject {
    func appendInitialUserMessage(text: String, imagesBase64: [String])
    func appendToolResults(_ results: [ToolResult])
    func appendUserTextMessage(_ text: String)
    func send(onTextDelta: @escaping (String) -> Void) async throws -> ProjectToolLoopResponse
}

struct ProjectToolLoopResponse {
    let textSegments: [String]
    let toolCalls: [ToolCall]
    let orderedBlocks: [ProjectToolLoopContentBlock]

    init(
        textSegments: [String],
        toolCalls: [ToolCall],
        orderedBlocks: [ProjectToolLoopContentBlock]? = nil
    ) {
        self.textSegments = textSegments
        self.toolCalls = toolCalls
        if let orderedBlocks {
            self.orderedBlocks = orderedBlocks
        } else {
            var fallback: [ProjectToolLoopContentBlock] = textSegments.map { .text($0) }
            fallback.append(contentsOf: toolCalls.map { .toolCall($0) })
            self.orderedBlocks = fallback
        }
    }
}
