import SwiftUI
import AppKit

struct TokenAwareHighlighter {
    /// Highlights code with proper token boundary respect
    static func highlight(code: String, language: String?) -> AttributedString {
        var attributed = AttributedString(code)

        // Get language config
        let config = languageConfig(for: language)

        // Track already-highlighted ranges to avoid overlaps
        var highlightedRanges: [Range<String.Index>] = []

        // 1. First highlight strings (highest priority)
        let stringRanges = highlightStrings(in: &attributed, code: code, config: config)
        highlightedRanges.append(contentsOf: stringRanges)

        // 2. Then highlight comments (skip string regions)
        let commentRanges = highlightComments(in: &attributed, code: code, config: config, excluding: highlightedRanges)
        highlightedRanges.append(contentsOf: commentRanges)

        // 3. Then highlight keywords (skip string and comment regions)
        highlightKeywords(in: &attributed, code: code, config: config, excluding: highlightedRanges)

        // 4. Finally highlight numbers (skip all highlighted regions)
        highlightNumbers(in: &attributed, code: code, excluding: highlightedRanges)

        return attributed
    }

    // MARK: - Language Configuration

    struct LanguageConfig {
        let keywordRegex: NSRegularExpression
        let lineCommentPrefix: String?
        let stringDelimiters: [Character]

        init(keywords: [String], lineCommentPrefix: String?, stringDelimiters: [Character]) {
            let alternatives = keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            // All alternatives are escaped literals from the fixed language vocabulary.
            keywordRegex = try! NSRegularExpression(pattern: "\\b(?:\(alternatives))\\b")
            self.lineCommentPrefix = lineCommentPrefix
            self.stringDelimiters = stringDelimiters
        }
    }

    private static func languageConfig(for language: String?) -> LanguageConfig {
        switch language?.lowercased() {
        case "swift": return swift
        case "python", "py": return python
        case "javascript", "js", "typescript", "ts": return javascript
        case "rust": return rust
        case "go", "golang": return go
        default: return TokenAwareHighlighterLanguageCatalog.config(for: language) ?? fallback
        }
    }

    private static let swift = LanguageConfig(
        keywords: ["func", "var", "let", "class", "struct", "enum", "protocol", "extension",
                  "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
                  "return", "throw", "throws", "try", "catch", "import", "public", "private",
                  "internal", "fileprivate", "open", "static", "final", "override", "mutating",
                  "init", "deinit", "self", "Self", "super", "nil", "true", "false", "async", "await"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\""]
    )

    private static let python = LanguageConfig(
        keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
                  "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield",
                  "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False",
                  "async", "await", "self"],
        lineCommentPrefix: "#",
        stringDelimiters: ["\"", "'"]
    )

    private static let javascript = LanguageConfig(
        keywords: ["function", "const", "let", "var", "class", "extends", "if", "else",
                  "for", "while", "do", "switch", "case", "default", "break", "continue",
                  "return", "throw", "try", "catch", "finally", "new", "this", "super",
                  "import", "export", "from", "as", "async", "await", "null", "undefined",
                  "true", "false", "typeof", "instanceof"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'", "`"]
    )

    private static let rust = LanguageConfig(
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait",
                  "pub", "mod", "use", "if", "else", "match", "for", "while", "loop",
                  "return", "break", "continue", "self", "Self", "super", "crate",
                  "async", "await", "move", "ref", "true", "false", "Some", "None", "Ok", "Err"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\""]
    )

    private static let go = LanguageConfig(
        keywords: ["func", "var", "const", "type", "struct", "interface", "package", "import",
                  "if", "else", "for", "range", "switch", "case", "default", "select",
                  "return", "break", "continue", "go", "defer", "chan", "map", "make", "new",
                  "nil", "true", "false"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "`"]
    )

    private static let fallback = LanguageConfig(
        keywords: ["function", "func", "def", "class", "struct", "if", "else", "for", "while",
                  "return", "var", "let", "const", "import", "true", "false", "null", "nil"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'"]
    )

    // MARK: - Highlighting Methods

    private static func highlightStrings(in attributed: inout AttributedString, code: String, config: LanguageConfig) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []

        for delimiter in config.stringDelimiters {
            let pattern = "\(delimiter)(?:[^\(delimiter)\\\\]|\\\\.)*\(delimiter)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                guard let swiftRange = Range(match.range, in: code),
                      let attrRange = Range(swiftRange, in: attributed) else { continue }
                attributed[attrRange].foregroundColor = OverlayPalette.success
                ranges.append(swiftRange)
            }
        }

        return ranges
    }

    private static func highlightComments(in attributed: inout AttributedString, code: String, config: LanguageConfig, excluding: [Range<String.Index>]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []

        // Line comments
        if let prefix = config.lineCommentPrefix {
            let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
            let pattern = "\(escapedPrefix).*$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return ranges }

            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                guard let swiftRange = Range(match.range, in: code) else { continue }

                // Skip if overlaps with excluded ranges
                if excluding.contains(where: { $0.overlaps(swiftRange) }) { continue }

                guard let attrRange = Range(swiftRange, in: attributed) else { continue }
                attributed[attrRange].foregroundColor = OverlayPalette.textTertiary
                ranges.append(swiftRange)
            }
        }

        return ranges
    }

    private static func highlightKeywords(in attributed: inout AttributedString, code: String, config: LanguageConfig, excluding: [Range<String.Index>]) {
        let nsRange = NSRange(code.startIndex..., in: code)
        for match in config.keywordRegex.matches(in: code, range: nsRange) {
            guard let swiftRange = Range(match.range, in: code),
                  !excluding.contains(where: { $0.overlaps(swiftRange) }),
                  let attrRange = Range(swiftRange, in: attributed) else { continue }
            attributed[attrRange].foregroundColor = OverlayPalette.speaker(3)
        }
    }

    private static func highlightNumbers(in attributed: inout AttributedString, code: String, excluding: [Range<String.Index>]) {
        let pattern = "\\b\\d+\\.?\\d*\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsRange = NSRange(code.startIndex..., in: code)
        for match in regex.matches(in: code, range: nsRange) {
            guard let swiftRange = Range(match.range, in: code) else { continue }

            // Skip if overlaps with excluded ranges
            if excluding.contains(where: { $0.overlaps(swiftRange) }) { continue }

            guard let attrRange = Range(swiftRange, in: attributed) else { continue }
            attributed[attrRange].foregroundColor = OverlayPalette.warning
        }
    }
}
