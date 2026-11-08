import Foundation

/// Provider neutral description of a tool. The concrete adapter maps this to the
/// Claude `tools` array or the OpenAI `tools[].function` shape.
struct ToolDefinition: Equatable {
    let name: String
    let description: String
    let inputSchema: JSONObject
    let isReadOnly: Bool

    static func == (lhs: ToolDefinition, rhs: ToolDefinition) -> Bool {
        lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.isReadOnly == rhs.isReadOnly
            && NSDictionary(dictionary: lhs.inputSchema.raw)
                .isEqual(to: rhs.inputSchema.raw)
    }
}

/// Request from the model: a tool call with arguments.
struct ToolCall: Equatable {
    let id: String
    let name: String
    let arguments: JSONObject

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && NSDictionary(dictionary: lhs.arguments.raw)
                .isEqual(to: rhs.arguments.raw)
    }
}

/// Response to the model: the tool's output.
struct ToolResult: Equatable {
    let toolCallID: String
    let isError: Bool
    let content: String
    let contentTruncated: Bool
    let overflowPath: String?

    init(
        toolCallID: String,
        isError: Bool = false,
        content: String,
        contentTruncated: Bool = false,
        overflowPath: String? = nil
    ) {
        self.toolCallID = toolCallID
        self.isError = isError
        self.content = content
        self.contentTruncated = contentTruncated
        self.overflowPath = overflowPath
    }

    static func error(toolCallID: String, message: String) -> ToolResult {
        ToolResult(toolCallID: toolCallID, isError: true, content: message, contentTruncated: false, overflowPath: nil)
    }
}

/// Lightweight wrapper around `[String: Any]` that gives Equatable / Hashable through NSDictionary.
/// Used for JSON Schema input and tool arguments where full Codable conformance would force every
/// leaf value to be a concrete type.
struct JSONObject {
    var raw: [String: Any]

    init(_ raw: [String: Any] = [:]) {
        self.raw = raw
    }

    subscript(key: String) -> Any? {
        get { raw[key] }
        set { raw[key] = newValue }
    }
}
