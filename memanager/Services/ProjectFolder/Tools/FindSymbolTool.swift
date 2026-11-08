import Foundation

struct FindSymbolTool: ProjectTool {
    let name = "find_symbol"
    let description = "Find declarations by exact symbol name with language-aware parsing for Swift, Python, Rust, C, and C++."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Exact symbol name to find."],
                "kind": ["type": "string", "description": "Optional declaration kind such as class, struct, enum, protocol, actor, extension, or typealias."],
                "path": ["type": "string", "description": "Optional subfolder relative to the project root."]
            ],
            "required": ["name"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let symbolName = ProjectToolHelpers.stringArgument(arguments, "name"), !symbolName.isEmpty else {
            return .error(toolCallID: callID, message: "Missing name argument.")
        }

        let service = ProjectSemanticQueryService(context: context)
        do {
            let (matches, note) = try service.findSymbol(
                named: symbolName,
                kind: ProjectToolHelpers.stringArgument(arguments, "kind"),
                path: ProjectToolHelpers.stringArgument(arguments, "path")
            )
            return ToolResult(
                toolCallID: callID,
                content: render(matches: matches, note: note),
                contentTruncated: matches.count >= context.config.maxSearchResults
            )
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }

    private func render(matches: [ProjectSymbolMatch], note: String?) -> String {
        var lines = ["matches:"]
        if matches.isEmpty {
            lines.append("(none)")
        } else {
            for (index, match) in matches.enumerated() {
                lines.append("match \(index + 1):")
                lines.append("kind: \(match.kind)")
                lines.append("name: \(match.name)")
                lines.append("path: \(match.path)")
                lines.append("line: \(match.line)")
                lines.append("signature: \(match.signature)")
            }
        }
        if let note {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
