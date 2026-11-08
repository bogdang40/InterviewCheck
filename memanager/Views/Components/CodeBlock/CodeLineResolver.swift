import Foundation

/// One row of a code block: its number, its text with the highlighter's
/// runs intact, and whether the current step added it.
struct CodeLine: Identifiable, Equatable {
    let number: Int
    let text: AttributedString
    let isNew: Bool

    var id: Int { number }
}

/// Splits code into rows so line numbers can sit beside wrapped lines.
/// Works on the highlighted string directly, which keeps token colors
/// that span the split intact. Pure so the split can be unit tested.
enum CodeLineResolver {
    static func lines(from attributed: AttributedString, newRange: ClosedRange<Int>?) -> [CodeLine] {
        let characters = attributed.characters
        var result: [CodeLine] = []
        var lineStart = characters.startIndex
        var cursor = characters.startIndex
        var number = 1

        while cursor < characters.endIndex {
            if characters[cursor] == "\n" {
                result.append(makeLine(attributed[lineStart..<cursor], number: number, newRange: newRange))
                number += 1
                cursor = characters.index(after: cursor)
                lineStart = cursor
            } else {
                cursor = characters.index(after: cursor)
            }
        }
        result.append(makeLine(attributed[lineStart..<characters.endIndex], number: number, newRange: newRange))
        return result
    }

    static func lines(from code: String, newRange: ClosedRange<Int>?) -> [CodeLine] {
        code.components(separatedBy: "\n").enumerated().map { offset, line in
            CodeLine(number: offset + 1, text: AttributedString(line), isNew: newRange?.contains(offset + 1) ?? false)
        }
    }

    /// Digits reserved in the gutter so numbers stay right aligned.
    static func gutterDigits(lineCount: Int) -> Int {
        max(String(max(lineCount, 1)).count, 2)
    }

    /// Badge text for the range a step added, phrased without dashes.
    static func newLinesLabel(for range: ClosedRange<Int>?) -> String? {
        guard let range else { return nil }
        if range.lowerBound == range.upperBound {
            return "Line \(range.lowerBound) new"
        }
        return "Lines \(range.lowerBound) to \(range.upperBound) new"
    }

    private static func makeLine(_ slice: AttributedSubstring, number: Int, newRange: ClosedRange<Int>?) -> CodeLine {
        CodeLine(number: number, text: AttributedString(slice), isNew: newRange?.contains(number) ?? false)
    }
}
