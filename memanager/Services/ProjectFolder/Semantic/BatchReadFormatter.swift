import Foundation

struct BatchReadFileResult {
    let path: String
    let content: String?
    let errorMessage: String?
    let isTruncated: Bool
}

final class BatchReadFormatter {
    static let maxFilesPerCall = 8
    static let maxCombinedCharacters = 40_000

    func format(results: [BatchReadFileResult]) -> (content: String, truncated: Bool) {
        let sections = results.enumerated().map { index, result in
            var lines = [
                "file \(index + 1):",
                "path: \(result.path)"
            ]
            if let errorMessage = result.errorMessage {
                lines.append("status: error")
                lines.append("error: \(errorMessage)")
            } else {
                lines.append("status: ok")
                lines.append("content:")
                lines.append(result.content ?? "")
            }
            return lines.joined(separator: "\n")
        }

        var content = sections.joined(separator: "\n\n")
        var truncated = results.contains(where: \.isTruncated)
        if content.count > Self.maxCombinedCharacters {
            content = String(content.prefix(Self.maxCombinedCharacters))
            content.append("\n\n(truncated at \(Self.maxCombinedCharacters) characters)")
            truncated = true
        }
        return (content, truncated)
    }
}
