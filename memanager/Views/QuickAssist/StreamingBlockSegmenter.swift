import Foundation

/// Split of a streaming draft into a stable, styleable prefix and a
/// volatile raw tail.
struct StreamingBlockSegmentation: Equatable {
    let committedText: String
    let tailText: String

    var committedLength: Int { committedText.count }
}

/// Decides how much of a streaming draft is safe to parse and style.
///
/// Rules: the boundary sits after the last completed paragraph (`\n\n`),
/// except when the draft currently ends inside an unterminated code or
/// mermaid fence, in which case the boundary is the START of that fence's
/// opening line (the open fence streams as raw text). The committed length
/// never regresses, so already styled content cannot lose its styling mid stream;
/// at settle, callers segment with `previousCommittedLength: draft.count`
/// to force the whole text committed.
enum StreamingBlockSegmenter {
    static func segment(draft: String, previousCommittedLength: Int) -> StreamingBlockSegmentation {
        let boundary = commitBoundary(in: draft)
        let clampedPrevious = min(max(previousCommittedLength, 0), draft.count)
        let committedLength = max(boundary, clampedPrevious)
        let splitIndex = draft.index(draft.startIndex, offsetBy: committedLength)
        return StreamingBlockSegmentation(
            committedText: String(draft[..<splitIndex]),
            tailText: String(draft[splitIndex...])
        )
    }

    private static func commitBoundary(in draft: String) -> Int {
        if let fenceStart = openFenceStartOffset(in: draft) {
            return fenceStart
        }
        if let range = draft.range(of: "\n\n", options: .backwards) {
            return draft.distance(from: draft.startIndex, to: range.upperBound)
        }
        return 0
    }

    /// Character offset of the opening line of a fence that has not closed
    /// yet, mirroring the fence grammar used by FencedMarkdownParser
    /// (three or more backticks or tildes, up to three leading spaces,
    /// closed by a run of the same marker at least as long).
    private static func openFenceStartOffset(in draft: String) -> Int? {
        var lineStartOffset = 0
        var openFence: (marker: Character, length: Int, start: Int)?

        for line in draft.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { lineStartOffset += line.count + 1 }

            let content = line.drop(while: { $0 == " " })
            let leadingSpaces = line.count - content.count
            guard leadingSpaces <= 3, let marker = content.first, marker == "`" || marker == "~" else {
                continue
            }
            let runLength = content.prefix(while: { $0 == marker }).count
            guard runLength >= 3 else { continue }

            if let fence = openFence {
                let rest = content.dropFirst(runLength)
                if marker == fence.marker,
                   runLength >= fence.length,
                   rest.allSatisfy({ $0 == " " }) {
                    openFence = nil
                }
            } else {
                openFence = (marker: marker, length: runLength, start: lineStartOffset)
            }
        }

        return openFence?.start
    }
}
