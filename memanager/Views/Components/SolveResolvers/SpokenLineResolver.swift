import Foundation

/// One line of code the way it is said aloud, with the line it came from
/// when that is known.
struct SpokenLine: Identifiable, Equatable {
    let id: Int
    let lineNumber: Int?
    let spoken: String

    var gutter: String {
        lineNumber.map { "L\($0)" } ?? ""
    }
}

/// Picks which lines of a step to read aloud: the lines the step added
/// when the range is known, else the snippet, else the whole listing.
enum SpokenLineResolver {
    static func lines(for step: ImplementationStep, style: SpokenCodeFormatter.Style) -> [SpokenLine] {
        let cumulativeLines = step.cumulativeCode.components(separatedBy: "\n")

        if let range = step.addedLineRange, !step.cumulativeCode.isEmpty {
            let lower = max(1, min(range.lowerBound, cumulativeLines.count))
            let upper = max(lower, min(range.upperBound, cumulativeLines.count))
            let numbered = (lower...upper).map { index in
                (index, SpokenCodeFormatter.format(cumulativeLines[index - 1], language: step.language, style: style))
            }
            let selected = numbered.filter { !$0.1.isEmpty }
            if !selected.isEmpty {
                return selected.enumerated().map { offset, pair in
                    SpokenLine(id: offset, lineNumber: pair.0, spoken: pair.1)
                }
            }
        }

        if !step.codeSnippet.isEmpty {
            let spoken = unnumbered(step.codeSnippet.components(separatedBy: "\n"), language: step.language, style: style)
            if !spoken.isEmpty {
                return spoken
            }
        }

        return unnumbered(cumulativeLines, language: step.language, style: style)
    }

    private static func unnumbered(_ lines: [String], language: String, style: SpokenCodeFormatter.Style) -> [SpokenLine] {
        lines
            .map { SpokenCodeFormatter.format($0, language: language, style: style) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { offset, spoken in SpokenLine(id: offset, lineNumber: nil, spoken: spoken) }
    }
}
