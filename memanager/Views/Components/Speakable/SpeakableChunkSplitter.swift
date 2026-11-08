import Foundation

/// One spoken chunk: a short paragraph the user can say in one breath.
struct SpeakableChunk: Identifiable, Equatable {
    let number: Int
    let content: String

    /// Position based identity keeps rows stable while text streams in.
    var id: Int { number }
}

/// Splits narration on blank lines. Pure so the chunk count the
/// teleprompter reports can be tested without a view.
enum SpeakableChunkSplitter {
    static let ellipsis = "\u{2026}"

    static func chunks(from text: String) -> [SpeakableChunk] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, content in SpeakableChunk(number: index + 1, content: content) }
    }

    /// The first line of the first chunk, cut to `limit` characters, for
    /// collapsed previews.
    static func preview(of text: String, limit: Int = 90) -> String? {
        guard let first = chunks(from: text).first else { return nil }
        let line = first.content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + ellipsis
    }
}
