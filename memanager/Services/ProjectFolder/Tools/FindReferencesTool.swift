import Foundation

struct FindReferencesTool: ProjectTool {
    let name = "find_references"
    let description = "Find declaration and usage references for a symbol with token boundary matching and language-aware declaration labeling."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "symbol": ["type": "string", "description": "Symbol name to search for."],
                "path": ["type": "string", "description": "Optional subfolder relative to the project root."]
            ],
            "required": ["symbol"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let symbol = ProjectToolHelpers.stringArgument(arguments, "symbol"), !symbol.isEmpty else {
            return .error(toolCallID: callID, message: "Missing symbol argument.")
        }

        let service = ProjectSemanticQueryService(context: context)
        do {
            let (matches, note) = try service.findReferences(
                symbol: symbol,
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

    private func render(matches: [ProjectReferenceMatch], note: String?) -> String {
        let groups = Dictionary(grouping: matches, by: \.kind)
        let orderedKinds: [ProjectReferenceKind] = [.declaration, .usage, .possibleUsage]
        var lines: [String] = []
        for kind in orderedKinds {
            lines.append("\(kind.rawValue)s:")
            let items = groups[kind] ?? []
            if items.isEmpty {
                lines.append("(none)")
                continue
            }
            for match in items {
                lines.append("path: \(match.path)")
                lines.append("line: \(match.line)")
                lines.append("snippet: \(match.snippet)")
            }
        }
        if let note {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
