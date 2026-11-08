import Foundation

struct FindTypeRelationshipsTool: ProjectTool {
    let name = "find_type_relationships"
    let description = "Summarize declarations, extensions or impl blocks, inheritance, conformances, and conformers for a type, protocol, or trait."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Type or protocol name to inspect."],
                "path": ["type": "string", "description": "Optional subfolder relative to the project root."]
            ],
            "required": ["name"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let name = ProjectToolHelpers.stringArgument(arguments, "name"), !name.isEmpty else {
            return .error(toolCallID: callID, message: "Missing name argument.")
        }

        let service = ProjectSemanticQueryService(context: context)
        do {
            let relationships = try service.typeRelationships(
                for: name,
                path: ProjectToolHelpers.stringArgument(arguments, "path")
            )
            return ToolResult(
                toolCallID: callID,
                content: render(relationships: relationships),
                contentTruncated: false
            )
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }

    private func render(relationships: ProjectTypeRelationships) -> String {
        var lines: [String] = []
        appendSymbols(section: "declarations", matches: relationships.declarations, to: &lines)
        appendSymbols(section: "extensions", matches: relationships.extensions, to: &lines)
        appendValues(section: "inherits from", values: relationships.inheritsFrom, to: &lines)
        appendValues(section: "conforms to", values: relationships.conformsTo, to: &lines)
        lines.append("conformers:")
        if relationships.conformers.isEmpty {
            lines.append("(none)")
        } else {
            for conformer in relationships.conformers {
                lines.append("relation: \(conformer.relation)")
                lines.append("kind: \(conformer.kind)")
                lines.append("name: \(conformer.name)")
                lines.append("path: \(conformer.path)")
                lines.append("line: \(conformer.line)")
            }
        }
        if let note = relationships.note {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    private func appendSymbols(section: String, matches: [ProjectSymbolMatch], to lines: inout [String]) {
        lines.append("\(section):")
        if matches.isEmpty {
            lines.append("(none)")
            return
        }
        for match in matches {
            lines.append("kind: \(match.kind)")
            lines.append("name: \(match.name)")
            lines.append("path: \(match.path)")
            lines.append("line: \(match.line)")
            lines.append("signature: \(match.signature)")
        }
    }

    private func appendValues(section: String, values: [String], to lines: inout [String]) {
        lines.append("\(section):")
        if values.isEmpty {
            lines.append("(none)")
            return
        }
        values.forEach { lines.append($0) }
    }
}
