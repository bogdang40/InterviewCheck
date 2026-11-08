import Foundation

extension MermaidDiagramChunker {
    static func collectNodeLabels(from statements: [String]) -> [String: String] {
        var labels: [String: String] = [:]
        for statement in statements {
            for line in statement.components(separatedBy: "\n") {
                collectNodeLabels(from: line, into: &labels)
            }
        }
        return labels
    }

    static func collectNodeLabels(from line: String, into labels: inout [String: String]) {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        let regexes = [bracketNodeLabelPattern, roundNodeLabelPattern].compactMap { $0 }

        for regex in regexes {
            let matches = regex.matches(in: line, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges >= 2 else { continue }
                let idRange = match.range(at: 1)
                guard idRange.location != NSNotFound else { continue }
                let identifier = nsLine.substring(with: idRange)
                guard labels[identifier] == nil else { continue }
                guard let label = extractedNodeLabel(from: match, line: nsLine) else { continue }
                labels[identifier] = label
            }
        }
    }

    private static func extractedNodeLabel(
        from match: NSTextCheckingResult,
        line: NSString
    ) -> String? {
        guard match.numberOfRanges >= 3 else { return nil }
        for index in 2..<match.numberOfRanges {
            let valueRange = match.range(at: index)
            guard valueRange.location != NSNotFound else { continue }
            let value = line.substring(with: valueRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            return decodeEscapedMermaidLabel(value)
        }
        return nil
    }

    static func declarationLinesForChunk(
        statements: [String],
        labelByIdentifier: [String: String]
    ) -> [String] {
        let referenced = referencedIdentifiers(in: statements)
        guard !referenced.isEmpty else { return [] }

        var declarations: [String] = []
        for identifier in referenced {
            guard let label = labelByIdentifier[identifier], !label.isEmpty else { continue }
            guard !hasLabelDeclaration(for: identifier, in: statements) else { continue }
            declarations.append(#"\#(identifier)["\#(escapedMermaidLabel(label))"]"#)
        }
        return declarations
    }

    private static func referencedIdentifiers(in statements: [String]) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for statement in statements {
            for rawLine in statement.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                guard line.range(of: edgePattern, options: .regularExpression) != nil else { continue }
                guard let (from, to) = extractEndpoints(from: line) else { continue }
                if seen.insert(from).inserted {
                    ordered.append(from)
                }
                if seen.insert(to).inserted {
                    ordered.append(to)
                }
            }
        }

        return ordered
    }

    private static func hasLabelDeclaration(for identifier: String, in statements: [String]) -> Bool {
        let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = "\\b\(escapedIdentifier)\\s*(\\[\\[|\\[|\\(\\(|\\(\\[|\\()"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }

        for statement in statements {
            for rawLine in statement.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let range = NSRange(location: 0, length: (line as NSString).length)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    return true
                }
            }
        }

        return false
    }

    private static func decodeEscapedMermaidLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func escapedMermaidLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func labelForChunkTitle(
        identifier: String,
        labelByIdentifier: [String: String]
    ) -> String {
        guard let label = labelByIdentifier[identifier], !label.isEmpty else {
            return identifier
        }
        let normalized = label
            .replacingOccurrences(of: "<br/>", with: " ")
            .replacingOccurrences(of: "<br />", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? identifier : normalized
    }

    static func chunkTitle(
        for statements: [String],
        index: Int,
        total: Int,
        labelByIdentifier: [String: String]
    ) -> String {
        guard let statement = statements.first(where: { !isCommentStatement($0) }) else {
            return "Step \(index + 1) of \(total)"
        }

        let edgeLine = statement
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.range(of: edgePattern, options: .regularExpression) != nil })

        if let edgeLine, let (from, to) = extractEndpoints(from: edgeLine) {
            let fromTitle = labelForChunkTitle(identifier: from, labelByIdentifier: labelByIdentifier)
            let toTitle = labelForChunkTitle(identifier: to, labelByIdentifier: labelByIdentifier)
            return "Step \(index + 1): \(fromTitle) -> \(toTitle)"
        }

        return "Step \(index + 1) of \(total)"
    }

    private static func extractEndpoints(from line: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: endpointPattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange) else {
            return nil
        }

        guard match.numberOfRanges >= 4,
              let fromRange = Range(match.range(at: 1), in: line),
              let toRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let from = String(line[fromRange])
        let to = String(line[toRange])
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return (from, to)
    }
}
