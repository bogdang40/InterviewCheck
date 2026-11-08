import Foundation

/// Job descriptions often arrive as HTML (sometimes HTML-escaped HTML).
/// This turns them into readable plain text without WebKit.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        var text = html
        // Escaped HTML ("&lt;p&gt;") is decoded first so its tags can go.
        if text.contains("&lt;") && !text.contains("<") { text = decodeEntities(text) }
        let replacements: [(String, String)] = [
            (#"(?is)<(script|style)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "\n\u{2022} "),
            (#"(?i)</(p|div|h[1-6]|ul|ol|tr|section|article)>"#, "\n\n"),
            (#"(?i)<(p|div|h[1-6]|ul|ol|tr|section|article)[^>]*>"#, "\n"),
            (#"<[^>]+>"#, ""),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ text: String) -> String {
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&nbsp;": " ", "&ndash;": "\u{2013}", "&mdash;": "\u{2014}", "&rsquo;": "\u{2019}",
                     "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&hellip;": "\u{2026}",
                     "&bull;": "\u{2022}"]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";") {
                let entity = String(text[index...semicolon])
                if let value = named[entity] {
                    result += value
                    index = text.index(after: semicolon)
                    continue
                }
                if entity.hasPrefix("&#") {
                    let digits = entity.dropFirst(2).dropLast()
                    let scalar = digits.hasPrefix("x") || digits.hasPrefix("X")
                        ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    if let scalar, let character = Unicode.Scalar(scalar) {
                        result.unicodeScalars.append(character)
                        index = text.index(after: semicolon)
                        continue
                    }
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}
