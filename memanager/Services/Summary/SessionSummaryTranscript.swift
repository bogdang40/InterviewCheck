import Foundation

/// The session snapshot can contain final text missing from individual entry rows.
/// Select one source for both the provider prompt and the local fallback.
enum SessionSummaryTranscript {
    case saved(String)
    case entries([TranscriptEntryRecord])

    init(savedText: String?, entries: [TranscriptEntryRecord]) {
        if let text = savedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            self = .saved(text)
        } else {
            self = .entries(entries)
        }
    }

    var promptBody: String {
        let text: String
        switch self {
        case .saved(let savedText):
            // Keep existing attribution exactly as saved. Do not manufacture entries
            // with a default speaker or the session's start time.
            text = savedText
        case .entries(let entries):
            guard !entries.isEmpty else { return "(no transcript captured)" }
            text = entries.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        }
        if text.count <= 40_000 { return text }
        return String(text.prefix(40_000)) + "\n[... transcript truncated ...]"
    }

    var fallbackLines: [String] {
        switch self {
        case .saved(let text):
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            var lines = ["Captured \(wordCount) words in the saved session transcript."]
            if text.count <= 240 {
                lines.append("Transcript excerpt: \(text)")
            } else {
                lines.append("Start of transcript: \(text.prefix(120))")
                lines.append("End of transcript: \(text.suffix(120))")
            }
            return lines
        case .entries(let entries):
            let wordCount = entries.reduce(0) {
                $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count
            }
            var lines = ["Captured \(entries.count) transcript entries (\(wordCount) words)."]
            if let first = entries.first {
                lines.append("Opened with: \(first.text.prefix(120))")
            }
            if let last = entries.last, entries.count > 1 {
                lines.append("Closed with: \(last.text.prefix(120))")
            }
            return lines
        }
    }
}
