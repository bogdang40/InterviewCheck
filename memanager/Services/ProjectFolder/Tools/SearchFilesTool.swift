import Foundation

/// Regex content search. Primary backend is `rg` via `RipgrepService`: fast,
/// `.gitignore` aware, supports context lines and multiline. Falls back to the
/// legacy `NSRegularExpression` walker if ripgrep is not installed so the tool
/// remains functional on machines without Homebrew.
struct SearchFilesTool: ProjectTool {
    let name = "search_files"
    let description = "Search file contents for a regex under the project root. Respects .gitignore. Supports context lines, multiline, file type filters."

    var inputSchema: JSONObject {
        JSONObject([
            "type": "object",
            "properties": [
                "pattern": ["type": "string", "description": "Regex pattern to search for."],
                "path": ["type": "string", "description": "Subfolder relative to root. Defaults to the root."],
                "caseSensitive": ["type": "boolean", "description": "Defaults to false (smart case)."],
                "fixedStrings": ["type": "boolean", "description": "Treat pattern as a literal string. Defaults to false."],
                "multiline": ["type": "boolean", "description": "Allow the pattern to span newlines. Defaults to false."],
                "contextBefore": ["type": "integer", "description": "Lines of context before each match (0 to 10)."],
                "contextAfter": ["type": "integer", "description": "Lines of context after each match (0 to 10)."],
                "fileTypes": ["type": "array", "items": ["type": "string"], "description": "Optional file type filters (ripgrep names, e.g. swift, py, rust)."],
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
        return LegacyRegexSearch(
            scopeURL: scopeURL,
            context: context,
            pattern: pattern,
            caseSensitive: ProjectToolHelpers.boolArgument(arguments, "caseSensitive", default: false)
        ).execute(callID: callID)
    }

    private func runRipgrep(
        callID: String,
        pattern: String,
        scope: URL,
        arguments: [String: Any],
        context: ProjectToolContext
    ) async -> ToolResult {
        var options = RipgrepService.SearchOptions(pattern: pattern, scope: scope)
        options.caseSensitive = ProjectToolHelpers.boolArgument(arguments, "caseSensitive", default: false)
        options.fixedStrings = ProjectToolHelpers.boolArgument(arguments, "fixedStrings", default: false)
        options.multiline = ProjectToolHelpers.boolArgument(arguments, "multiline", default: false)
        options.contextBefore = min(max(ProjectToolHelpers.intArgument(arguments, "contextBefore") ?? 0, 0), 10)
        options.contextAfter = min(max(ProjectToolHelpers.intArgument(arguments, "contextAfter") ?? 0, 0), 10)
        options.includeHidden = ProjectToolHelpers.boolArgument(arguments, "includeHidden", default: false)
        options.maxCount = context.config.maxSearchResults
        options.maxFileSizeBytes = context.config.maxFileSizeBytes
        if let types = arguments["fileTypes"] as? [String] { options.fileTypes = types }

        do {
            let rawMatches = try await RipgrepService.shared.search(options).map { match in
                RipgrepMatch(
                    relativePath: try context.access.rootRelativePath(
                        match.relativePath, scopeURL: scope, rootURL: context.rootURL
                    ),
                    lineNumber: match.lineNumber,
                    byteOffset: match.byteOffset,
                    lineText: match.lineText,
                    submatches: match.submatches,
                    contextBefore: match.contextBefore,
                    contextAfter: match.contextAfter
                )
            }
            let filtered = context.config.allowSensitiveReads
                ? rawMatches
                : rawMatches.filter { !ProjectToolHelpers.isSensitivePath($0.relativePath) }
            if filtered.isEmpty {
                return ToolResult(toolCallID: callID, content: "No matches.", contentTruncated: false)
            }
            let showContext = options.contextBefore > 0 || options.contextAfter > 0
            let capped = Array(filtered.prefix(max(0, options.maxCount)))
            let body = SearchResultFormatter().format(capped, options: .init(showContext: showContext))
            let truncated = filtered.count >= options.maxCount
            let content = truncated ? body + "\n(truncated at \(options.maxCount) matches)" : body
            return ToolResult(toolCallID: callID, content: content, contentTruncated: truncated)
        } catch {
            return .error(toolCallID: callID, message: error.localizedDescription)
        }
    }
}
