import Foundation

/// Sanitize and repair helpers for Mermaid diagram source.
enum MermaidSanitizer {
    private static let singleBracketNodeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z0-9_]+)\[(?!\[)([^\[\]\n]+?)\](?!\])"#
    )

    /// Sanitize Mermaid diagram to fix common AI-generated syntax errors
    static func sanitizeMermaid(_ diagram: String) -> String {
        var result = diagram
        
        // Remove HTML-style comments that Mermaid doesn't support in some contexts
        // AI often generates <!-- comment --> or %% comments in wrong places
        result = result.replacingOccurrences(of: "<!--[^>]*-->", with: "", options: .regularExpression)

        // Normalize escaped newlines inside labels to HTML line breaks.
        result = result.replacingOccurrences(of: "\\n", with: "<br/>")
        
        // Fix common ER diagram issues - remove inline comments after attributes
        // erDiagram often fails with comments like "string name PK // this is the name"
        let lines = result.components(separatedBy: "\n")
        result = lines.map { line in
            // Remove trailing // comments in ER diagrams (not valid Mermaid syntax)
            if line.contains(" //") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                return line.components(separatedBy: "//").first?.trimmingCharacters(in: .whitespaces) ?? line
            }
            return line
        }.joined(separator: "\n")
        
        // Remove %% comments that appear inline (keep only line-start comments)
        result = result.replacingOccurrences(of: "(?<!^)%%[^\n]*", with: "", options: .regularExpression)
        
        // Clean up any resulting empty lines or excessive whitespace
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Second-pass deterministic repair for known parser edge cases.
    static func repairMermaidForRetry(_ diagram: String) -> String {
        var repaired = sanitizeMermaid(diagram)

        // Mermaid label parser is sensitive to unbalanced brackets around wrapped labels.
        repaired = repaired.replacingOccurrences(of: "<br/>(", with: "<br/> ")
        repaired = repaired.replacingOccurrences(of: "<br/>[", with: "<br/> ")
        repaired = repaired.replacingOccurrences(of: "<br/>{", with: "<br/> ")

        // Normalize smart punctuation that can break some parser paths.
        repaired = repaired.replacingOccurrences(of: "“", with: "\"")
        repaired = repaired.replacingOccurrences(of: "”", with: "\"")
        repaired = repaired.replacingOccurrences(of: "’", with: "'")
        repaired = repaired.replacingOccurrences(of: "–", with: "-")
        repaired = repaired.replacingOccurrences(of: "—", with: "-")

        if isFlowchartDiagram(repaired) {
            repaired = quoteRiskyFlowchartLabels(in: repaired)
        }

        return repaired.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFlowchartDiagram(_ diagram: String) -> Bool {
        let firstMeaningful = diagram
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let firstMeaningful else { return false }
        return firstMeaningful.hasPrefix("flowchart") || firstMeaningful.hasPrefix("graph")
    }

    private static func quoteRiskyFlowchartLabels(in diagram: String) -> String {
        guard let regex = singleBracketNodeRegex else { return diagram }
        let lines = diagram.components(separatedBy: "\n")
        return lines.map { line in
            quoteRiskyFlowchartLabels(inLine: line, regex: regex)
        }.joined(separator: "\n")
    }

    private static func quoteRiskyFlowchartLabels(
        inLine line: String,
        regex: NSRegularExpression
    ) -> String {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, options: [], range: nsRange)
        guard !matches.isEmpty else { return line }

        var updated = line
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let nodeRange = Range(match.range(at: 1), in: updated),
                  let labelRange = Range(match.range(at: 2), in: updated) else {
                continue
            }

            let nodeID = String(updated[nodeRange])
            let rawLabel = String(updated[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard needsQuotedFlowchartLabel(rawLabel) else { continue }

            let escaped = escapeFlowchartLabel(rawLabel)
            let replacement = "\(nodeID)[\"\(escaped)\"]"
            if let fullRange = Range(match.range, in: updated) {
                updated.replaceSubrange(fullRange, with: replacement)
            }
        }

        return updated
    }

    private static func needsQuotedFlowchartLabel(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        if (label.hasPrefix("\"") && label.hasSuffix("\"")) ||
            (label.hasPrefix("'") && label.hasSuffix("'")) {
            return false
        }
        if label.contains("<br/>") { return true }
        if label.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return true }
        let riskyCharacters = CharacterSet(charactersIn: "(){}:/\\<>")
        return label.rangeOfCharacter(from: riskyCharacters) != nil
    }

    private static func escapeFlowchartLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
