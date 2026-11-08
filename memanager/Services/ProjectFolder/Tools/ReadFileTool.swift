import Foundation

/// Streams a single text file, honors offset/limit with a byte budget, and
/// returns images or PDFs as base64. Uses `ProjectTextReadServiceV2` to keep the
/// tool body tiny and the read pipeline testable in isolation.
struct ReadFileTool: ProjectTool {
    let name = "read_file"
    let description = "Read the contents of a text file (path relative to the project root). Returns UTF 8 text with line numbers, respects offset and limit, and stops at a byte budget. Images and PDFs are returned as base64."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path relative to the project root."],
                "offset": ["type": "integer", "description": "One based starting line. Defaults to 1."],
                "limit": ["type": "integer", "description": "Maximum lines to return. Defaults to 2000."],
                "byteBudget": ["type": "integer", "description": "Maximum bytes of text to emit. Defaults to 262144 (256 KB)."]
            ],
            "required": ["path"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let rawPath = ProjectToolHelpers.stringArgument(arguments, "path") else {
            return .error(toolCallID: callID, message: "Missing required path argument.")
        }
        let offset = max(ProjectToolHelpers.intArgument(arguments, "offset") ?? 1, 1)
        let limit = max(ProjectToolHelpers.intArgument(arguments, "limit") ?? 2000, 1)
        let byteBudget = max(
            ProjectToolHelpers.intArgument(arguments, "byteBudget") ?? ProjectTextReadServiceV2.defaultByteBudget,
            4096
        )
        let service = ProjectTextReadServiceV2(context: context)
        do {
            let result = try service.read(path: rawPath, offset: offset, limit: limit, byteBudget: byteBudget)
            recordStamp(for: rawPath, context: context)
            return ToolResult(
                toolCallID: callID,
                content: result.modelFacingText,
                contentTruncated: result.isTruncated
            )
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }

    private func recordStamp(for relativePath: String, context: ProjectToolContext) {
        guard let registry = context.fileTime,
              let url = try? context.access.canonicalize(relativePath: relativePath, rootURL: context.rootURL),
              let stamp = FileTimeRegistry.Stamp.of(url: url) else { return }
        Task { await registry.record(path: relativePath, stamp: stamp) }
    }
}
