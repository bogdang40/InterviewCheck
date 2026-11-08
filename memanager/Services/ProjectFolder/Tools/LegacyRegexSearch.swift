import Foundation

/// Fallback regex search used when `rg` is unavailable. Matches the previous
/// behavior of `SearchFilesTool`: enumerate the tree via `FileManager`, skip
/// excluded directories and sensitive files, test each line with
/// `NSRegularExpression`. Slow on large repos; kept so the tool degrades
/// gracefully on machines without Homebrew.
struct LegacyRegexSearch {
    let scopeURL: URL
    let context: ProjectToolContext
    let pattern: String
    let caseSensitive: Bool

    func execute(callID: String) -> ToolResult {
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return .error(toolCallID: callID, message: "Invalid regex: \(error.localizedDescription)")
        }
        var matches: [String] = []
        let maxResults = context.config.maxSearchResults
        let excludes = Set(context.config.excludePatterns)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .error(toolCallID: callID, message: "Could not enumerate folder.")
        }
        outer: for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if excludes.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            let relative = url.path.replacingOccurrences(of: context.rootURL.path + "/", with: "")
            if !context.config.allowSensitiveReads, ProjectToolHelpers.isSensitivePath(relative) { continue }
            if let size = values?.fileSize, size > context.config.maxFileSizeBytes { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.prefix(8192).contains(0) { continue }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    matches.append("\(relative):\(index + 1): \(line)")
                    if matches.count >= maxResults { break outer }
                }
            }
        }
        if matches.isEmpty {
            return ToolResult(toolCallID: callID, content: "No matches. (ripgrep not installed; using slower backend)", contentTruncated: false)
        }
        let header = "(ripgrep not installed; using slower backend)\n"
        let output = header + matches.joined(separator: "\n")
        let truncated = matches.count >= maxResults
        return ToolResult(
            toolCallID: callID,
            content: truncated ? output + "\n(truncated at \(maxResults) matches)" : output,
            contentTruncated: truncated
        )
    }
}
