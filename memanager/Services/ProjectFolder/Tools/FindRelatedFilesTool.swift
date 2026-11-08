import Foundation

struct FindRelatedFilesTool: ProjectTool {
    let name = "find_related_files"
    let description = "Find likely related files such as test pairs, extension files, and nearby feature files."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path relative to the project root."]
            ],
            "required": ["path"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let path = ProjectToolHelpers.stringArgument(arguments, "path"), !path.isEmpty else {
            return .error(toolCallID: callID, message: "Missing path argument.")
        }

        let service = ProjectSemanticQueryService(context: context)
        do {
            let related = try service.relatedFiles(for: path)
            return ToolResult(
                toolCallID: callID,
                content: render(related: related),
                contentTruncated: related.count >= ProjectSemanticQueryService.maxRelatedFiles
            )
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }

    private func render(related: [ProjectRelatedFile]) -> String {
        var lines = ["matches:"]
        if related.isEmpty {
            lines.append("(none)")
        } else {
            for (index, file) in related.enumerated() {
                lines.append("match \(index + 1):")
                lines.append("path: \(file.path)")
                lines.append("reason: \(file.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
