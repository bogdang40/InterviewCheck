import Foundation

final class ProjectOutlineFallbackScanner {
    private let headingRegex = try! NSRegularExpression(pattern: #"^\s*#+\s+(.+)$"#)
    private let markerRegex = try! NSRegularExpression(pattern: #"^\s*(?://|#|--)\s*(MARK:|SECTION:)\s*(.+)$"#)
    private let importRegex = try! NSRegularExpression(pattern: #"^\s*(import|from)\s+(.+)$"#)

    func outlineRows(for text: String) -> [ProjectOutlineRow] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let lineNumber = index + 1
            if let row = parse(regex: importRegex, in: line, line: lineNumber, kind: "import", group: 2) {
                return row
            }
            if let row = parse(regex: headingRegex, in: line, line: lineNumber, kind: "heading", group: 1) {
                return row
            }
            if let row = parse(regex: markerRegex, in: line, line: lineNumber, kind: "marker", group: 2) {
                return row
            }
            return nil
        }
    }

    private func parse(
        regex: NSRegularExpression,
        in line: String,
        line lineNumber: Int,
        kind: String,
        group: Int
    ) -> ProjectOutlineRow? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: group), in: line) else {
            return nil
        }
        let summary = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return ProjectOutlineRow(line: lineNumber, kind: kind, summary: summary)
    }
}
