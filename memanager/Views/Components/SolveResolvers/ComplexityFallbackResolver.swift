import Foundation

/// Recovers time, space and the trade off from the raw Complexity text
/// when the section parser handed back nothing. The solve prompt asks for
/// the notation inside the bold label, which the parser deliberately
/// leaves alone, so the renderer reads that shape itself rather than
/// dropping to plain markdown for the most common answer.
enum ComplexityFallbackResolver {
    private struct Entry {
        let label: String
        var lines: [String]
    }

    private static let notationRegex = try? NSRegularExpression(pattern: #"O\([^)]+\)"#)
    private static let labelPrefixes: Set<Character> = ["*", "#", "_", " ", "\t"]
    private static let timeLabels = ["time"]
    private static let spaceLabels = ["space"]
    private static let tradeOffLabels = ["trade-off", "trade off", "tradeoff"]

    static func resolve(_ content: ComplexityContent) -> ComplexityContent {
        guard content.isEmpty else { return content }
        return recover(from: content.rawContent) ?? content
    }

    static func recover(from raw: String) -> ComplexityContent? {
        let entries = entries(in: raw)
        let time = analysis(for: timeLabels, type: .time, in: entries)
        let space = analysis(for: spaceLabels, type: .space, in: entries)
        guard time != nil || space != nil else { return nil }
        let tradeOff = entries.first { tradeOffLabels.contains($0.label) }.map { body(of: $0) }
        return ComplexityContent(
            time: time,
            space: space,
            tradeOff: tradeOff.flatMap { $0.isEmpty ? nil : $0 },
            rawContent: raw
        )
    }

    private static func entries(in raw: String) -> [Entry] {
        var entries: [Entry] = []
        for line in raw.components(separatedBy: "\n") {
            if let (label, remainder) = labelAndRemainder(of: line) {
                entries.append(Entry(label: label, lines: [remainder]))
            } else if !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
            }
        }
        return entries
    }

    /// Splits a line such as `**Time: O(n)** detail` into ("time", "O(n) detail").
    private static func labelAndRemainder(of line: String) -> (String, String)? {
        let stripped = line.drop(while: { labelPrefixes.contains($0) })
        guard let colon = stripped.firstIndex(of: ":") else { return nil }
        let label = stripped[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
        let known = timeLabels + spaceLabels + tradeOffLabels
        guard known.contains(label) else { return nil }
        return (label, String(stripped[stripped.index(after: colon)...]))
    }

    private static func analysis(
        for labels: [String],
        type: ComplexityAnalysis.ComplexityType,
        in entries: [Entry]
    ) -> ComplexityAnalysis? {
        guard let entry = entries.first(where: { labels.contains($0.label) }) else { return nil }
        let text = body(of: entry)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let regex = notationRegex, let match = regex.firstMatch(in: text, range: fullRange) else {
            return ComplexityAnalysis(notation: "", breakdown: text, type: type)
        }
        let notation = nsText.substring(with: match.range)
        let breakdown = nsText.replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ComplexityAnalysis(notation: notation, breakdown: breakdown, type: type)
    }

    private static func body(of entry: Entry) -> String {
        entry.lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
