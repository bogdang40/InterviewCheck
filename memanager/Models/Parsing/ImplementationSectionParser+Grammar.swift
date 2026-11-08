import Foundation

extension ImplementationSectionParser {

    struct StepHeader {
        let number: Int
        let title: String
        let lineIndex: Int
    }

    // Matches "Step N:" format
    private static let stepHeaderRegex = try? NSRegularExpression(
        pattern: #"^Step\s+(\d+)(?:\s*[:\-–—\.]\s*(.+))?$"#,
        options: [.caseInsensitive]
    )
    
    // Matches numbered list format: "1.", "1)", "1:"
    private static let numberedListRegex = try? NSRegularExpression(
        pattern: #"^(\d+)\s*[\.\)\:]\s*(.*)$"#,
        options: []
    )
    
    // Matches alternative naming: "Phase 1:", "Part 1:", "Section 1:"
    private static let alternativeStepRegex = try? NSRegularExpression(
        pattern: #"^(?:Phase|Part|Section)\s+(\d+)(?:\s*[:\-–—\.]\s*(.+))?$"#,
        options: [.caseInsensitive]
    )

    private static let codeFenceRegex = try? NSRegularExpression(
        pattern: #"^[ ]{0,3}(`{3,}|~{3,})([^\n`~]*)\n([\s\S]*?)^[ ]{0,3}\1[ ]*$"#,
        options: [.anchorsMatchLines]
    )

    private static let newLineRangeRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:#|//)\s*NEW:\s*lines?\s*(\d+)(?:-(\d+))?"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    private static let newLineStripRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:#|//)\s*NEW:[^\n]*\n?"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    static func extractStepHeaders(from lines: [String]) -> [StepHeader] {
        var headers: [StepHeader] = []
        var inCodeBlock = false
        var fenceChar: Character = "`"
        var fenceLength = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inCodeBlock {
                if isClosingFence(trimmed, char: fenceChar, minLength: fenceLength) {
                    inCodeBlock = false
                }
                continue
            }

            if let fence = matchFence(trimmed) {
                inCodeBlock = true
                fenceChar = fence.char
                fenceLength = fence.length
                continue
            }

            if let header = parseStepHeader(from: trimmed) {
                headers.append(StepHeader(number: header.number, title: header.title, lineIndex: index))
            }
        }

        return headers
    }

    private static func parseStepHeader(from line: String) -> (number: Int, title: String)? {
        var candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // Strip markdown heading markers
        if candidate.hasPrefix("#") {
            let withoutHashes = candidate.drop(while: { $0 == "#" })
            candidate = String(withoutHashes).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip bold/italic markers
        candidate = candidate
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let nsString = candidate as NSString
        let range = NSRange(location: 0, length: nsString.length)

        // Try "Step N:" format first
        if let regex = stepHeaderRegex,
           let match = regex.firstMatch(in: candidate, range: range),
           match.range(at: 1).location != NSNotFound {
            let numberStr = nsString.substring(with: match.range(at: 1))
            if let number = Int(numberStr) {
                var title = "Step \(number)"
                if match.range(at: 2).location != NSNotFound {
                    let rawTitle = nsString.substring(with: match.range(at: 2))
                    let cleanedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedTitle.isEmpty {
                        title = cleanedTitle
                    }
                }
                return (number, title)
            }
        }
        
        // Try "Phase/Part/Section N:" format
        if let regex = alternativeStepRegex,
           let match = regex.firstMatch(in: candidate, range: range),
           match.range(at: 1).location != NSNotFound {
            let numberStr = nsString.substring(with: match.range(at: 1))
            if let number = Int(numberStr) {
                var title = "Step \(number)"
                if match.range(at: 2).location != NSNotFound {
                    let rawTitle = nsString.substring(with: match.range(at: 2))
                    let cleanedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedTitle.isEmpty {
                        title = cleanedTitle
                    }
                }
                return (number, title)
            }
        }
        
        // Try numbered list format "1.", "1)", "1:" - but only at start of significant lines
        // Avoid matching inline numbered items by requiring the title to be substantive
        if let regex = numberedListRegex,
           let match = regex.firstMatch(in: candidate, range: range),
           match.range(at: 1).location != NSNotFound {
            let numberStr = nsString.substring(with: match.range(at: 1))
            if let number = Int(numberStr), number <= 20 { // Reasonable step limit
                var title = "Step \(number)"
                if match.range(at: 2).location != NSNotFound {
                    let rawTitle = nsString.substring(with: match.range(at: 2))
                    let cleanedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only accept if there's a meaningful title (avoid matching random numbered lists)
                    if cleanedTitle.count >= 5 {
                        title = cleanedTitle
                        return (number, title)
                    }
                }
            }
        }

        return nil
    }

    static func extractCodeBlocks(from text: String) -> [(language: String?, code: String, range: Range<String.Index>)] {
        guard let regex = codeFenceRegex else { return [] }
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)

        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }

            var language: String?
            if match.range(at: 2).location != NSNotFound {
                let rawLanguage = nsString.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawLanguage.isEmpty {
                    language = rawLanguage
                }
            }

            var code = ""
            if match.range(at: 3).location != NSNotFound {
                code = nsString.substring(with: match.range(at: 3))
                while code.hasSuffix("\n") {
                    code = String(code.dropLast())
                }
            }

            return (language: language, code: code, range: matchRange)
        }
    }

    static func stripCodeBlocks(from text: String) -> String {
        guard let regex = codeFenceRegex else { return text }
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        let lowered = token.lowercased()

        switch lowered {
        case "py", "python3":
            return "python"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "c++", "cpp", "cxx":
            return "cpp"
        case "c#":
            return "csharp"
        default:
            return lowered
        }
    }

    static func parseNewLineRange(from code: String) -> ClosedRange<Int>? {
        guard let regex = newLineRangeRegex else { return nil }
        let nsString = code as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: code, range: range),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }

        let startStr = nsString.substring(with: match.range(at: 1))
        guard let start = Int(startStr), start > 0 else { return nil }

        if match.range(at: 2).location != NSNotFound {
            let endStr = nsString.substring(with: match.range(at: 2))
            guard let end = Int(endStr), end >= start else { return nil }
            return start...end
        }

        return start...start
    }

    static func stripNewLineMarker(from code: String) -> String {
        guard let regex = newLineStripRegex else {
            return code.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let nsString = code as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let stripped = regex.stringByReplacingMatches(in: code, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchFence(_ line: String) -> (char: Character, length: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let firstChar = trimmed.first else { return nil }
        guard firstChar == "`" || firstChar == "~" else { return nil }

        var fenceLength = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex && trimmed[index] == firstChar {
            fenceLength += 1
            index = trimmed.index(after: index)
        }

        guard fenceLength >= 3 else { return nil }
        return (firstChar, fenceLength)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.first == char else { return false }

        var fenceLength = 0
        for c in trimmed {
            if c == char {
                fenceLength += 1
            } else if c == " " || c == "\t" {
                continue
            } else {
                return false
            }
        }

        return fenceLength >= minLength
    }

    /// Extracts [-> code:label] link from text
}
