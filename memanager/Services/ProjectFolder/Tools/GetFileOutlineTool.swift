import Foundation

struct GetFileOutlineTool: ProjectTool {
    let name = "get_file_outline"
    let description = "Return imports, includes, use statements, declarations, markers, and major sections for a file with a text fallback for unsupported languages."

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
            let outline = try service.outline(path: path)
            return ToolResult(
                toolCallID: callID,
                content: render(outline: outline),
                contentTruncated: outline.isTruncated
            )
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }

    private func render(outline: ProjectFileOutline) -> String {
        var lines = ["rows:"]
        if outline.rows.isEmpty {
            lines.append("(none)")
        } else {
            for row in outline.rows {
                lines.append("line: \(row.line)")
                lines.append("kind: \(row.kind)")
                lines.append("summary: \(row.summary)")
            }
        }
        if outline.isTruncated {
            lines.append("(truncated at \(ProjectSemanticQueryService.maxOutlineRows) rows)")
        }
        if let note = outline.note {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
