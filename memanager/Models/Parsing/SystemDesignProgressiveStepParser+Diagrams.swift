import Foundation

extension SystemDesignProgressiveStepParser {
    // MARK: - Mermaid Diagram Extraction
    
    /// Extracts mermaid diagram from text (content within ```mermaid ... ```)
    private static let mermaidFenceRegex = try? NSRegularExpression(
        pattern: #"^[ ]{0,3}(`{3,}|~{3,})\s*mermaid\s*\n([\s\S]*?)^[ ]{0,3}\1[ ]*$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    static func extractMermaidDiagram(from text: String) -> String? {
        guard let regex = mermaidFenceRegex else { return nil }
        
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        guard let match = regex.firstMatch(in: text, range: range),
              match.range(at: 2).location != NSNotFound else {
            return nil
        }
        
        return nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static func stripMermaidBlocks(from text: String) -> String {
        guard let regex = mermaidFenceRegex else { return text }
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
