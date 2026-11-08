import Foundation

/// Produces an indented tree of the project folder structure. Reads from the
/// warm `FSIndexActor` when available (fast, gitignore aware). Falls back to
/// a `FileManager` walk for the cold first call.
struct GetStructureTool: ProjectTool {
    let name = "get_structure"
    let description = "Produce an indented tree of the project folder's structure. Honors .gitignore. Defaults to depth 3, max depth 6."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Subfolder relative to root. Defaults to the root."],
                "depth": ["type": "integer", "description": "Max depth to descend. Defaults to 3, capped at 6."]
            ],
            "required": [] as [String]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        let rawPath = ProjectToolHelpers.stringArgument(arguments, "path") ?? ""
        let requestedDepth = min(max(ProjectToolHelpers.intArgument(arguments, "depth") ?? 3, 1), 6)
        let rootURL: URL
        do {
            rootURL = try context.access.canonicalize(relativePath: rawPath, rootURL: context.rootURL)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
        if let index = context.fsIndex, await index.isWarm() {
            return await buildFromIndex(callID: callID, index: index, prefix: rawPath, maxDepth: requestedDepth)
        }
        var output: [String] = []
        GetStructureWalker.append(
            url: rootURL,
            depth: 0,
            maxDepth: requestedDepth,
            indent: 0,
            output: &output,
            config: context.config
        )
        if output.count > 1000 {
            output = Array(output.prefix(1000))
            output.append("(truncated at 1000 entries)")
        }
        return ToolResult(
            toolCallID: callID,
            content: output.joined(separator: "\n"),
            contentTruncated: output.last?.hasPrefix("(truncated") ?? false
        )
    }

    private func buildFromIndex(
        callID: String,
        index: FSIndexActor,
        prefix: String,
        maxDepth: Int
    ) async -> ToolResult {
        var output: [String] = []
        await walk(index: index, subpath: prefix, depth: 0, maxDepth: maxDepth, indent: 0, output: &output)
        if output.count > 1000 {
            output = Array(output.prefix(1000))
            output.append("(truncated at 1000 entries)")
        }
        if output.isEmpty { output.append("(empty)") }
        return ToolResult(
            toolCallID: callID,
            content: output.joined(separator: "\n"),
            contentTruncated: output.last?.hasPrefix("(truncated") ?? false
        )
    }

    private func walk(
        index: FSIndexActor,
        subpath: String,
        depth: Int,
        maxDepth: Int,
        indent: Int,
        output: inout [String]
    ) async {
        guard depth < maxDepth else { return }
        let listing = await index.listing(of: subpath)
        let indentPrefix = String(repeating: "  ", count: indent)
        for dir in listing.subdirectories {
            output.append("\(indentPrefix)\(dir)/")
            let nested = subpath.isEmpty ? dir : subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + dir
            await walk(index: index, subpath: nested, depth: depth + 1, maxDepth: maxDepth, indent: indent + 1, output: &output)
            if output.count > 1000 { return }
        }
        for file in listing.files {
            let name = (file.relativePath as NSString).lastPathComponent
            output.append("\(indentPrefix)\(name)")
            if output.count > 1000 { return }
        }
    }
}
