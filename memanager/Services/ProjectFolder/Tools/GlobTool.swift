import Foundation

/// Filename glob. Primary backend is `rg --files --glob`. Results are ranked
/// newest first via a 16 way concurrent stat pass. Falls back to the legacy
/// FileManager walk when `rg` is not installed.
struct GlobTool: ProjectTool {
    let name = "glob"
    let description = "Find files by name pattern (glob style). Supports **, *, and ?. Respects .gitignore. Returns paths sorted newest first by modification time."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "pattern": ["type": "string", "description": "Glob pattern, e.g. **/*.swift"],
                "path": ["type": "string", "description": "Subfolder relative to root. Defaults to the root."],
                "fileTypes": ["type": "array", "items": ["type": "string"], "description": "Optional ripgrep file type filter, e.g. [\"swift\",\"py\"]."],
                "includeHidden": ["type": "boolean", "description": "Include dotfiles and dot-directories. Defaults to false."]
            ],
            "required": ["pattern"]
        ])
    }

    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult {
        guard let pattern = ProjectToolHelpers.stringArgument(arguments, "pattern"), !pattern.isEmpty else {
            return .error(toolCallID: callID, message: "Missing pattern argument.")
        }
        let subpath = ProjectToolHelpers.stringArgument(arguments, "path") ?? ""
        let scopeURL: URL
        do {
            scopeURL = try context.access.canonicalize(relativePath: subpath, rootURL: context.rootURL)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }

        if RipgrepBinaryLocator.shared.locate() != nil {
            return await runRipgrep(callID: callID, pattern: pattern, scope: scopeURL, arguments: arguments, context: context)
        }
        return LegacyGlobWalker(scopeURL: scopeURL, rootURL: context.rootURL, pattern: pattern, context: context).execute(callID: callID)
    }

    private func runRipgrep(
        callID: String,
        pattern: String,
        scope: URL,
        arguments: [String: Any],
        context: ProjectToolContext
    ) async -> ToolResult {
        var options = RipgrepService.FileListOptions(scope: scope)
        options.pattern = pattern
        options.includeHidden = ProjectToolHelpers.boolArgument(arguments, "includeHidden", default: false)
        if let types = arguments["fileTypes"] as? [String] { options.fileTypes = types }

        do {
            let hits = try await RipgrepService.shared.files(options)
            let filtered = context.config.allowSensitiveReads
                ? hits
                : hits.filter { !ProjectToolHelpers.isSensitivePath($0.relativePath) }
            if filtered.isEmpty {
                return ToolResult(toolCallID: callID, content: "No matches.", contentTruncated: false)
            }
            let paths = try filtered.map {
                try context.access.rootRelativePath($0.relativePath, scopeURL: scope, rootURL: context.rootURL)
            }
            let dates = await ConcurrentStat.modificationDates(relativePaths: paths, root: context.rootURL)
            let sorted = paths.sorted { lhs, rhs in
                (dates[lhs] ?? .distantPast) > (dates[rhs] ?? .distantPast)
            }
            let capped = Array(sorted.prefix(context.config.maxSearchResults))
            let truncated = sorted.count > capped.count
            let body = capped.joined(separator: "\n")
            let content = truncated ? body + "\n(truncated at \(context.config.maxSearchResults) results)" : body
            return ToolResult(toolCallID: callID, content: content, contentTruncated: truncated)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }
}
