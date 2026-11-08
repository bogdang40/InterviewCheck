import Foundation

enum FencedMarkdownSegmentKind {
    case text(String)
    case code(languageHint: String?, code: String)
}

struct FencedMarkdownSegment: Identifiable {
    let position: Int
    var id: Int { position }
    let kind: FencedMarkdownSegmentKind
}

enum FencedMarkdownLanguageClassifier {
    static func primaryLanguage(from languageHint: String?) -> String? {
        guard let languageHint else { return nil }
        let trimmed = languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let firstToken = trimmed.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let token = String(firstToken).trimmingCharacters(in: CharacterSet(charactersIn: "{}[]()<>`'\",;"))
        guard !token.isEmpty else { return nil }
        return token.lowercased()
    }

    static func isMermaidLanguage(_ languageHint: String?) -> Bool {
        guard let language = primaryLanguage(from: languageHint) else { return false }
        return language == "mermaid" || language == "mmd"
    }
}

enum FencedMarkdownParser {
    private static let fenceRegex = try? NSRegularExpression(
        pattern: #"^[ ]{0,3}(`{3,}|~{3,})([^\n`~]*)\n([\s\S]*?)^[ ]{0,3}\1[ ]*$"#,
        options: [.anchorsMatchLines]
    )

    static func parse(_ text: String) -> [FencedMarkdownSegment] {
        guard let fenceRegex else {
            return [FencedMarkdownSegment(position: 0, kind: .text(text))]
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = fenceRegex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty {
            return [FencedMarkdownSegment(position: 0, kind: .text(text))]
        }

        var segments: [FencedMarkdownSegment] = []
        var lastIndex = text.startIndex
        var nextPosition = 0

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            appendTextSegment(
                source: text,
                range: lastIndex..<matchRange.lowerBound,
                segments: &segments,
                nextPosition: &nextPosition
            )

            let languageHint = extractLanguageHint(in: text, from: match)
            let code = extractCode(in: text, from: match)

            segments.append(FencedMarkdownSegment(
                position: nextPosition,
                kind: .code(languageHint: languageHint, code: code)
            ))
            nextPosition += 1
            lastIndex = matchRange.upperBound
        }

        appendTextSegment(
            source: text,
            range: lastIndex..<text.endIndex,
            segments: &segments,
            nextPosition: &nextPosition
        )

        return segments
    }

    private static func appendTextSegment(
        source: String,
        range: Range<String.Index>,
        segments: inout [FencedMarkdownSegment],
        nextPosition: inout Int
    ) {
        guard !range.isEmpty else { return }
        let chunk = String(source[range])
        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segments.append(FencedMarkdownSegment(position: nextPosition, kind: .text(chunk)))
        nextPosition += 1
    }

    private static func extractLanguageHint(in text: String, from match: NSTextCheckingResult) -> String? {
        let languageRange = match.range(at: 2)
        guard languageRange.location != NSNotFound,
              let range = Range(languageRange, in: text) else {
            return nil
        }
        let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func extractCode(in text: String, from match: NSTextCheckingResult) -> String {
        let codeRange = match.range(at: 3)
        guard codeRange.location != NSNotFound,
              let range = Range(codeRange, in: text) else {
            return ""
        }

        var code = String(text[range])
        while code.hasSuffix("\n") {
            code = String(code.dropLast())
        }
        return code
    }
}
