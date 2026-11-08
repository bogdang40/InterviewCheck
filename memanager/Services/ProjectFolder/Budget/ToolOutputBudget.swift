import Foundation

/// Uniform output budget applied to every tool result. Caps lines and bytes so
/// a single call cannot blow the model's context window. Spills the full
/// payload to `ToolOutputCacheDir` and returns a preview plus a continuation
/// hint pointing at the spill file.
final class ToolOutputBudget {
    static let shared = ToolOutputBudget()

    struct Limits: Equatable {
        let maxLines: Int
        let maxBytes: Int

        init(maxLines: Int = 500, maxBytes: Int = 64 * 1024) {
            self.maxLines = maxLines
            self.maxBytes = maxBytes
        }
    }

    struct Outcome: Equatable {
        let content: String
        let truncated: Bool
        let overflowPath: String?
    }

    private let cache: ToolOutputCacheDir

    init(cache: ToolOutputCacheDir = .shared) {
        self.cache = cache
    }

    func apply(_ content: String, limits: Limits = Limits()) -> Outcome {
        let byteCount = content.utf8.count
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if byteCount <= limits.maxBytes, lines.count <= limits.maxLines {
            return Outcome(content: content, truncated: false, overflowPath: nil)
        }

        var previewLines: [String] = []
        var emittedBytes = 0
        for line in lines {
            if previewLines.count >= limits.maxLines { break }
            let size = line.utf8.count + (previewLines.isEmpty ? 0 : 1)
            if emittedBytes + size > limits.maxBytes { break }
            previewLines.append(String(line))
            emittedBytes += size
        }
        let preview = previewLines.joined(separator: "\n")
        let overflowURL = try? cache.write(content)
        let hint: String
        if let url = overflowURL {
            hint = "\n(truncated; full output saved to \(url.path))"
        } else {
            hint = "\n(truncated)"
        }
        return Outcome(
            content: preview + hint,
            truncated: true,
            overflowPath: overflowURL?.path
        )
    }
}
