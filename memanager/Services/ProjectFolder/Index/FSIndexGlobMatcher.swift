import Foundation

/// Compiles a glob pattern into an `NSRegularExpression`. Supports `**` for
/// any number of path segments, `*` for any characters within a segment, and
/// `?` for a single non slash character.
struct FSIndexGlobMatcher {
    let regex: NSRegularExpression

    init?(pattern: String) {
        let regexString = "^" + Self.globToRegex(pattern) + "$"
        guard let compiled = try? NSRegularExpression(pattern: regexString) else { return nil }
        self.regex = compiled
    }

    func matches(_ relativePath: String) -> Bool {
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        return regex.firstMatch(in: relativePath, options: [], range: range) != nil
    }

    private static func globToRegex(_ glob: String) -> String {
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
