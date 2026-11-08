import Foundation

/// Direct Claude HTTP client for the tool calling loop. Kept separate from `ClaudeProvider`
/// because the tool harness has different turn shapes (tool_use, tool_result) and a different
/// response lifecycle (streamed tool iterations).
///
/// Owns a mutable messages array that grows turn by turn across the loop.
final class ProjectToolClaudeClient: ProjectToolLoopClient {
    enum ClientError: Error, LocalizedError {
        case invalidAPIKey
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "Claude API key is missing."
            case .invalidResponse: return "Claude returned an unexpected response."
            }
        }
    }

    private struct ParsedResponse {
        let textSegments: [String]
        let toolCalls: [ToolCall]
        let orderedBlocks: [ProjectToolLoopContentBlock]
        let rawContent: [[String: Any]]
    }

    private let apiKey: String
    private let model: String
    private let systemPrompt: String
    private let transport: NetworkTransport
    private var messages: [[String: Any]] = []
    private let tools: [[String: Any]]
    private let forceToolsOnFirstTurn: Bool
    private var isFirstRequest: Bool = true

    init(
        apiKey: String,
        model: String,
        systemPrompt: String,
        tools: [ToolDefinition],
        forceToolsOnFirstTurn: Bool = false,
        transport: NetworkTransport = URLSessionNetworkTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.transport = transport
        self.forceToolsOnFirstTurn = forceToolsOnFirstTurn
        self.tools = tools.map { definition in
            [
                "name": definition.name,
                "description": definition.description,
                "input_schema": definition.inputSchema.raw
            ]
        }
    }

    /// Append the initial user message. Content blocks accept text strings and base64 JPEG
    /// images. The client does not decide what to send; SessionController composes the message.
    func appendInitialUserMessage(text: String, imagesBase64: [String]) {
        var content: [[String: Any]] = []
        for image in imagesBase64 {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": image
                ]
            ])
        }
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        messages.append(["role": "user", "content": content])
    }

    /// Append user message containing one or more `tool_result` blocks.
    func appendToolResults(_ results: [ToolResult]) {
        var content: [[String: Any]] = []
        for result in results {
            content.append([
                "type": "tool_result",
                "tool_use_id": result.toolCallID,
                "content": result.content,
                "is_error": result.isError
            ])
        }
        messages.append(["role": "user", "content": content])
    }

    func appendUserTextMessage(_ text: String) {
        guard !text.isEmpty else { return }
        messages.append([
            "role": "user",
            "content": [["type": "text", "text": text]]
        ])
    }

    /// Send the current conversation + tools to Claude. Returns parsed response.
    func send(onTextDelta: @escaping (String) -> Void) async throws -> ProjectToolLoopResponse {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw ClientError.invalidAPIKey }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            if forceToolsOnFirstTurn && isFirstRequest {
                body["tool_choice"] = ["type": "any"]
            }
        }
        isFirstRequest = false
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var stream = ProjectToolClaudeStream()
        try await ProjectToolStreamReader.consume(request, transport: transport) { payload in
            try stream.consume(payload, onTextDelta: onTextDelta)
        }
        try Task.checkCancellation()
        let parsed = try Self.parse(data: stream.responseData())
        messages.append(["role": "assistant", "content": Self.normalizedAssistantContent(parsed.rawContent)])
        return ProjectToolLoopResponse(
            textSegments: parsed.textSegments,
            toolCalls: parsed.toolCalls,
            orderedBlocks: parsed.orderedBlocks
        )
    }

    private static func parse(data: Data) throws -> ParsedResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClientError.invalidResponse
        }
        var textSegments: [String] = []
        var toolCalls: [ToolCall] = []
        var orderedBlocks: [ProjectToolLoopContentBlock] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textSegments.append(text)
                    orderedBlocks.append(.text(text))
                }
            case "tool_use":
                guard
                    let id = block["id"] as? String,
                    let name = block["name"] as? String
                else { continue }
                let input = (block["input"] as? [String: Any]) ?? [:]
                let call = ToolCall(id: id, name: name, arguments: JSONObject(input))
                toolCalls.append(call)
                orderedBlocks.append(.toolCall(call))
            default:
                continue
            }
        }
        return ParsedResponse(
            textSegments: textSegments,
            toolCalls: toolCalls,
            orderedBlocks: orderedBlocks,
            rawContent: content
        )
    }

    private static func normalizedAssistantContent(_ content: [[String: Any]]) -> [[String: Any]] {
        guard let firstToolIndex = content.firstIndex(where: { ($0["type"] as? String) == "tool_use" }) else {
            return content
        }
        let hasTrailingNonTool = content[firstToolIndex...].contains { ($0["type"] as? String) != "tool_use" }
        guard hasTrailingNonTool else { return content }
        let nonToolContent = content.filter { ($0["type"] as? String) != "tool_use" }
        let toolContent = content.filter { ($0["type"] as? String) == "tool_use" }
        return nonToolContent + toolContent
    }
}
