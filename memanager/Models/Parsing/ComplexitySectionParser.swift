import Foundation

/// Parses the Complexity section of a mentor response.
enum ComplexitySectionParser {
    // MARK: - Complexity Section Parser

    static func parseComplexity(_ text: String) -> ComplexityContent {
        let timeRaw = MarkdownSectionGrammar.extractContent(after: "Time", in: text)
        let spaceRaw = MarkdownSectionGrammar.extractContent(after: "Space", in: text)
        let tradeOff = MarkdownSectionGrammar.extractContent(after: "Trade-off", in: text)

        return ComplexityContent(
            time: parseComplexityAnalysis(timeRaw, type: .time),
            space: parseComplexityAnalysis(spaceRaw, type: .space),
            tradeOff: tradeOff,
            rawContent: text
        )
    }

    private static func parseComplexityAnalysis(_ text: String?, type: ComplexityAnalysis.ComplexityType) -> ComplexityAnalysis? {
        guard let text = text, !text.isEmpty else { return nil }

        // Extract O(...) notation
        var notation = "O(?)"
        let notationPattern = #"O\([^)]+\)"#
        if let regex = try? NSRegularExpression(pattern: notationPattern),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            notation = (text as NSString).substring(with: match.range)
        }

        // The rest is the breakdown
        var breakdown = text
        if let regex = try? NSRegularExpression(pattern: notationPattern) {
            breakdown = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ComplexityAnalysis(notation: notation, breakdown: breakdown, type: type)
    }
}
