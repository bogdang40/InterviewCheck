import Foundation

/// Direct OpenAI Chat Completions client for the iterative project tool loop. GPT 5.4 supports
/// function calling on Chat Completions, which lets the harness mirror Claude's request ->
/// tool call -> tool result cycle without changing the rest of Quick Assist.
final class ProjectToolOpenAIClient: ProjectToolLoopClient {
    enum ClientError: Error, LocalizedError {
        case invalidAPIKey
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "OpenAI API key is missing."
            case .invalidResponse: return "OpenAI returned an unexpected response."
            }
        }
    }

    private struct ParsedResponse {
        let textSegments: [String]
        let toolCalls: [ToolCall]
        let orderedBlocks: [ProjectToolLoopContentBlock]
        let assistantMessage: [String: Any]
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
                "type": "function",
                "function": [
                    "name": definition.name,
                    "description": definition.description,
                    "parameters": definition.inputSchema.raw
                ]
            ]
        }
    }

    func appendInitialUserMessage(text: String, imagesBase64: [String]) {
        var content: [[String: Any]] = []
        for image in imagesBase64 {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image)"
                ]
            ])
        }
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        messages.append(["role": "user", "content": content])
    }

    func appendToolResults(_ results: [ToolResult]) {
        for result in results {
            let content = result.isError ? "ERROR: \(result.content)" : result.content
            messages.append([
                "role": "tool",
                "tool_call_id": result.toolCallID,
                "content": content
            ])
        }
    }

    func appendUserTextMessage(_ text: String) {
        guard !text.isEmpty else { return }
        messages.append([
            "role": "user",
            "content": [["type": "text", "text": text]]
        ])
    }

    func send(onTextDelta: @escaping (String) -> Void) async throws -> ProjectToolLoopResponse {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw ClientError.invalidAPIKey }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": buildMessages()
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["parallel_tool_calls"] = true
            body["tool_choice"] = (forceToolsOnFirstTurn && isFirstRequest) ? "required" : "auto"
        }
        isFirstRequest = false
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var stream = ProjectToolOpenAIStream()
        try await ProjectToolStreamReader.consume(request, transport: transport) { payload in
            try stream.consume(payload, onTextDelta: onTextDelta)
        }
        try Task.checkCancellation()
        let parsed = try Self.parse(data: stream.responseData())
        messages.append(parsed.assistantMessage)
        return ProjectToolLoopResponse(
            textSegments: parsed.textSegments,
            toolCalls: parsed.toolCalls,
            orderedBlocks: parsed.orderedBlocks
        )
    }

    private func buildMessages() -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": [["type": "text", "text": systemPrompt]]
            ]
        ] + messages
    }

    private static func parse(data: Data) throws -> ParsedResponse {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ClientError.invalidResponse
        }

        let textSegments = parseTextSegments(content: message["content"])
        let toolCalls = parseToolCalls(rawToolCalls: message["tool_calls"])
        var assistantMessage: [String: Any] = ["role": "assistant"]
        assistantMessage["content"] = message["content"] ?? NSNull()
        if let rawToolCalls = message["tool_calls"] {
            assistantMessage["tool_calls"] = rawToolCalls
        }
        var orderedBlocks: [ProjectToolLoopContentBlock] = []
        orderedBlocks.append(contentsOf: textSegments.map { .text($0) })
        orderedBlocks.append(contentsOf: toolCalls.map { .toolCall($0) })
        return ParsedResponse(
            textSegments: textSegments,
            toolCalls: toolCalls,
            orderedBlocks: orderedBlocks,
            assistantMessage: assistantMessage
        )
    }

    private static func parseTextSegments(content: Any?) -> [String] {
        if let content = content as? String, !content.isEmpty {
            return [content]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            if let text = block["text"] as? String {
                return text
            }
            if let nestedText = block["text"] as? [String: Any] {
                return nestedText["value"] as? String
            }
            return nil
        }
    }

    private static func parseToolCalls(rawToolCalls: Any?) -> [ToolCall] {
        guard let entries = rawToolCalls as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard
                let id = entry["id"] as? String,
                let function = entry["function"] as? [String: Any],
                let name = function["name"] as? String
            else {
                return nil
            }
            let argumentsString = function["arguments"] as? String ?? "{}"
            let argumentsObject: [String: Any]
            if let data = argumentsString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                argumentsObject = decoded
            } else {
                argumentsObject = [:]
            }
            return ToolCall(id: id, name: name, arguments: JSONObject(argumentsObject))
        }
    }
}
