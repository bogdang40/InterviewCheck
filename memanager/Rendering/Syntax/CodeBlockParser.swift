import SwiftUI
import AppKit

// MARK: - Code Block Parser

/// Extracts code blocks from markdown-formatted text

struct CodeBlockParser {
    struct CodeBlock: Identifiable {
        let id = UUID()
        let language: String?
        let code: String
        let label: String?

        init(language: String?, code: String, label: String? = nil) {
            self.language = language
            self.code = code
            self.label = label
        }
    }

    /// Extracts [label: name] from a code comment
    static func extractLabel(from code: String) -> String? {
        let pattern = #"\[label:\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsString = code as NSString
        let range = NSRange(location: 0, length: nsString.length)

        guard let match = regex.firstMatch(in: code, range: range),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }

        return nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    /// Parses markdown text and extracts fenced code blocks
    /// Handles edge cases: indented fences, nested backticks, tilde fences
    static func parse(_ text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []

        // Pattern handles:
        // 1. Optional leading whitespace (0-3 spaces for indented fences)
        // 2. 3+ backticks OR 3+ tildes (capture group 1 for matching closing)
        // 3. Optional language hint (capture group 2)
        // 4. Code content until matching/longer fence (capture group 3)
        let fencePattern = #"^[ ]{0,3}(`{3,}|~{3,})([^\n`~]*)\n([\s\S]*?)^[ ]{0,3}\1[ ]*$"#

        guard let regex = try? NSRegularExpression(pattern: fencePattern, options: [.anchorsMatchLines]) else {
            // Fallback to simple parsing
            return parseSimple(text)
        }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)

        if matches.isEmpty {
            // No fenced blocks found
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(CodeBlock(language: nil, code: text))
            }
            return blocks
        }

        for match in matches {
            // Group 2: language hint
            let languageRange = match.range(at: 2)
            var language: String? = nil
            if languageRange.location != NSNotFound {
                let rawLang = nsString.substring(with: languageRange)
                    .trimmingCharacters(in: .whitespaces)
                if !rawLang.isEmpty {
                    language = rawLang
                }
            }

            // Group 3: code content
            let codeRange = match.range(at: 3)
            if codeRange.location != NSNotFound {
                var code = nsString.substring(with: codeRange)
                // Remove trailing newline if present
                if code.hasSuffix("\n") {
                    code = String(code.dropLast())
                }
                let label = extractLabel(from: code)
                blocks.append(CodeBlock(language: language, code: code, label: label))
            }
        }

        return blocks
    }

    /// Simple fallback parser for when regex fails
    private static func parseSimple(_ text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var currentLanguage: String?
        var currentCode: [String] = []
        var fenceChar: Character = "`"
        var fenceLength = 3

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Check for fence start/end
            if !inCodeBlock {
                // Check for opening fence
                if let match = matchFence(trimmedLine) {
                    fenceChar = match.char
                    fenceLength = match.length
                    currentLanguage = match.language
                    inCodeBlock = true
                    continue
                }
            } else {
                // Check for closing fence (must be at least as long as opening)
                if isClosingFence(trimmedLine, char: fenceChar, minLength: fenceLength) {
                    blocks.append(CodeBlock(
                        language: currentLanguage,
                        code: currentCode.joined(separator: "\n")
                    ))
                    currentCode = []
                    currentLanguage = nil
                    inCodeBlock = false
                    continue
                }
                currentCode.append(line)
            }
        }

        // Handle unclosed code block
        if inCodeBlock && !currentCode.isEmpty {
            blocks.append(CodeBlock(
                language: currentLanguage,
                code: currentCode.joined(separator: "\n")
            ))
        }

        // If no fenced blocks found, treat entire content as code
        if blocks.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(CodeBlock(language: nil, code: text))
        }

        return blocks
    }

    private static func matchFence(_ line: String) -> (char: Character, length: Int, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }

        let firstChar = trimmed.first!
        guard firstChar == "`" || firstChar == "~" else { return nil }

        var fenceLength = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == firstChar {
            fenceLength += 1
            idx = trimmed.index(after: idx)
        }

        guard fenceLength >= 3 else { return nil }

        let remainder = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
        // Language hint should not contain fence characters
        if remainder.contains("`") || remainder.contains("~") {
            return nil
        }

        return (firstChar, fenceLength, remainder.isEmpty ? nil : remainder)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty && trimmed.first == char else { return false }

        var fenceLength = 0
        for c in trimmed {
            if c == char {
                fenceLength += 1
            } else if c == " " || c == "\t" {
                continue
            } else {
                return false // Non-whitespace after fence
            }
        }

        return fenceLength >= minLength
    }

    /// Removes code block markers from text for direct code content
    static func stripCodeBlockMarkers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeBlock = !inCodeBlock
                continue
            }
            result.append(line)
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Token-Aware Syntax Highlighter

/// Provides token-aware syntax highlighting that respects string/comment boundaries
