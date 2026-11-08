import Foundation

/// Fallback `glob` implementation used when `rg` is not installed. Reproduces
/// the previous hand rolled glob to regex + FileManager walk behavior so the
/// tool still works without Homebrew.
struct LegacyGlobWalker {
    let scopeURL: URL
    let rootURL: URL
    let pattern: String
    let context: ProjectToolContext

    func execute(callID: String) -> ToolResult {
        let regex: NSRegularExpression
        do {
            let regexString = "^" + globToRegex(pattern) + "$"
            regex = try NSRegularExpression(pattern: regexString, options: [])
        } catch {
            return .error(toolCallID: callID, message: "Invalid glob pattern.")
        }
        let manager = FileManager.default
        let excludes = Set(context.config.excludePatterns)
        let maxResults = context.config.maxSearchResults
        guard let enumerator = manager.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .error(toolCallID: callID, message: "Could not enumerate folder.")
        }
        var candidates: [(path: String, modified: Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if excludes.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true { continue }
            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let range = NSRange(relative.startIndex..., in: relative)
            if regex.firstMatch(in: relative, options: [], range: range) != nil {
                candidates.append((relative, values?.contentModificationDate ?? .distantPast))
                if candidates.count >= maxResults { break }
            }
        }
        let sorted = candidates.sorted(by: { $0.modified > $1.modified }).map { $0.path }
        if sorted.isEmpty {
            return ToolResult(toolCallID: callID, content: "No matches.", contentTruncated: false)
        }
        return ToolResult(
            toolCallID: callID,
            content: sorted.joined(separator: "\n"),
            contentTruncated: candidates.count >= maxResults
        )
    }

    private func globToRegex(_ glob: String) -> String {
        var regex = ""
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                let nextIndex = glob.index(after: index)
                if nextIndex < glob.endIndex, glob[nextIndex] == "*" {
                    regex += ".*"
                    index = glob.index(after: nextIndex)
                    if index < glob.endIndex, glob[index] == "/" {
                        index = glob.index(after: index)
                    }
                    continue
                } else {
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                regex += "\\" + String(character)
            default:
                regex += String(character)
            }
            index = glob.index(after: index)
        }
        return regex
    }
}
