import Foundation

/// Returns metadata about a single file or directory. Reads from the warm
/// `FSIndexActor` when available, otherwise stats the filesystem directly.
/// Marks `.gitignore` membership so the model can decide whether to open it.
struct FileInfoTool: ProjectTool {
    let name = "file_info"
    let description = "Return metadata (size, kind, modified date, ignored flag, line count for text) about a single file or directory."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Path relative to the project root."]
            ],
            "required": ["path"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let rawPath = ProjectToolHelpers.stringArgument(arguments, "path") else {
            return .error(toolCallID: callID, message: "Missing path argument.")
        }
        let resolved: URL
        do {
            resolved = try context.access.canonicalize(relativePath: rawPath, rootURL: context.rootURL)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: resolved.path) else {
            return .error(toolCallID: callID, message: "Could not stat file.")
        }
        let size = (attrs[.size] as? Int) ?? 0
        let modified = attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let type = attrs[.type] as? FileAttributeType
        let kind: String
        switch type {
        case .typeDirectory: kind = "directory"
        case .typeSymbolicLink: kind = "symlink"
        case .typeRegular: kind = "file"
        default: kind = "other"
        }
        let indexed: FileRecord? = await fetchIndexedRecord(path: rawPath, context: context)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines: [String] = [
            "path: \(rawPath)",
            "kind: \(kind)",
            "size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) bytes)",
            "modified: \(formatter.string(from: modified))"
        ]
        if let indexed {
            lines.append("language: \(indexed.languageKind.rawValue)")
            lines.append("ignored: \(indexed.isIgnored)")
        }
        if kind == "file" {
            let allowsContentRead = context.config.allowSensitiveReads || !ProjectToolHelpers.isSensitivePath(rawPath)
            if !allowsContentRead {
                lines.append("lines: skipped (sensitive file policy)")
            } else if size > context.config.maxFileSizeBytes {
                lines.append("lines: skipped (file exceeds read cap)")
            } else if let data = try? Data(contentsOf: resolved),
                      !data.prefix(8192).contains(0),
                      let text = String(data: data, encoding: .utf8) {
                let lineCount = text.components(separatedBy: "\n").count
                lines.append("lines: \(lineCount)")
            }
        }
        return ToolResult(toolCallID: callID, content: lines.joined(separator: "\n"), contentTruncated: false)
    }

    private func fetchIndexedRecord(path: String, context: ProjectToolContext) async -> FileRecord? {
        guard let index = context.fsIndex, await index.isWarm() else { return nil }
        return await index.record(relativePath: path)
    }
}
