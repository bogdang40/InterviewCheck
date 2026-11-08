import Foundation

/// Reads the direct children of a directory (relative to root). Primary path
/// reads from the warm `FSIndexActor` so listings are instantaneous; falls
/// back to `FileManager` when the index is still warming.
struct ListDirectoryTool: ProjectTool {
    let name = "list_directory"
    let description = "List files and subdirectories inside a folder, relative to the project root. Returns up to 500 entries with a size or kind suffix. Honors .gitignore."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Folder path relative to the project root. Use an empty string for the root."
                ],
                "includeIgnored": ["type": "boolean", "description": "Include entries that .gitignore would hide. Defaults to false."]
            ],
            "required": [] as [String]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        let rawPath = ProjectToolHelpers.stringArgument(arguments, "path") ?? ""
        let includeIgnored = ProjectToolHelpers.boolArgument(arguments, "includeIgnored", default: false)
        do {
            _ = try context.access.canonicalize(relativePath: rawPath, rootURL: context.rootURL)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
        if let index = context.fsIndex, await index.isWarm() {
            let listing = await index.listing(of: rawPath, includeIgnored: includeIgnored)
            return formatIndexed(callID: callID, listing: listing)
        }
        return fallbackFileManager(callID: callID, rawPath: rawPath, context: context)
    }

    private func formatIndexed(callID: String, listing: FSIndexActor.DirectoryListing) -> ToolResult {
        var lines: [String] = []
        for dir in listing.subdirectories { lines.append("\(dir)/") }
        for file in listing.files {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            let name = (file.relativePath as NSString).lastPathComponent
            let suffix = file.isIgnored ? "  \(formatted)  (ignored)" : "  \(formatted)"
            lines.append("\(name)\(suffix)")
        }
        let capped = Array(lines.prefix(500))
        let truncated = lines.count > capped.count
        var content = capped.joined(separator: "\n")
        if truncated {
            content.append("\n(truncated, \(lines.count - capped.count) more entries)")
        }
        if content.isEmpty { content = "(empty)" }
        return ToolResult(toolCallID: callID, content: content, contentTruncated: truncated)
    }

    private func fallbackFileManager(callID: String, rawPath: String, context: ProjectToolContext) -> ToolResult {
        let resolved: URL
        do {
            resolved = try context.access.canonicalize(relativePath: rawPath, rootURL: context.rootURL)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
        let manager = FileManager.default
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let contents = try manager.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            let filtered = contents
                .filter { !context.access.isExcluded(name: $0.lastPathComponent, patterns: context.config.excludePatterns) }
                .sorted { lhs, rhs in lhs.lastPathComponent < rhs.lastPathComponent }
            let capped = Array(filtered.prefix(500))
            let lines = capped.map { url -> String in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { return "\(url.lastPathComponent)/" }
                if let size = values?.fileSize {
                    let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    return "\(url.lastPathComponent)  \(formatted)"
                }
                return url.lastPathComponent
            }
            var output = lines.joined(separator: "\n")
            var truncated = false
            if filtered.count > capped.count {
                output.append("\n(truncated, \(filtered.count - capped.count) more entries)")
                truncated = true
            }
            return ToolResult(toolCallID: callID, content: output.isEmpty ? "(empty)" : output, contentTruncated: truncated)
        } catch {
            return .error(toolCallID: callID, message: "Could not list directory: \(error.localizedDescription)")
        }
    }
}
