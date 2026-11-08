import Foundation

struct ReadFilesBatchTool: ProjectTool {
    let name = "read_files_batch"
    let description = "Read multiple text files in one call. Applies the same read only and file size policies as read_file."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "files": [
                    "type": "array",
                    "description": "Array of file requests. Each item supports path, offset, and limit.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"],
                            "offset": ["type": "integer"],
                            "limit": ["type": "integer"]
                        ],
                        "required": ["path"]
                    ]
                ]
            ],
            "required": ["files"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let entries = ProjectToolHelpers.dictionaryArrayArgument(arguments, "files"), !entries.isEmpty else {
            return .error(toolCallID: callID, message: "Missing files argument.")
        }
        if entries.count > BatchReadFormatter.maxFilesPerCall {
            return .error(
                toolCallID: callID,
                message: "read_files_batch accepts at most \(BatchReadFormatter.maxFilesPerCall) files per call."
            )
        }

        let formatter = BatchReadFormatter()
        let service = ProjectTextReadServiceV2(context: context)
        let results = entries.map { entry -> BatchReadFileResult in
            let path = ProjectToolHelpers.stringArgument(entry, "path") ?? "(missing path)"
            let offset = max(ProjectToolHelpers.intArgument(entry, "offset") ?? 1, 1)
            let limit = max(ProjectToolHelpers.intArgument(entry, "limit") ?? 2000, 1)
            do {
                let result = try service.read(path: path, offset: offset, limit: limit, byteBudget: ProjectTextReadServiceV2.defaultByteBudget)
                return BatchReadFileResult(
                    path: path,
                    content: result.modelFacingText,
                    errorMessage: nil,
                    isTruncated: result.isTruncated
                )
            } catch {
                return BatchReadFileResult(
                    path: path,
                    content: nil,
                    errorMessage: error.localizedDescription,
                    isTruncated: false
                )
            }
        }
        let formatted = formatter.format(results: results)
        return ToolResult(
            toolCallID: callID,
            content: formatted.content,
            contentTruncated: formatted.truncated
        )
    }
}
