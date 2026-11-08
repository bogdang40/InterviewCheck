import Foundation

/// Deterministic and conservative Mermaid splitter focused on readability.
/// If structure safety is uncertain, it always returns a single unsplit chunk.
struct MermaidDiagramChunker {
    private static let splitEligibleHeaderPattern = #"^(flowchart|graph)\b"#
    static let edgePattern = #"(-->|---|==>|-.->|--x|x--|--o|o--|<-->|<-.->)"#
    static let endpointPattern = #"^\s*([A-Za-z0-9_]+).*(-->|---|==>|-.->|--x|x--|--o|o--|<-->|<-.->).*\b([A-Za-z0-9_]+)\s*$"#
    static let bracketNodeLabelPattern = try? NSRegularExpression(
        pattern: #"\b([A-Za-z0-9_]+)\s*\[(?:"((?:\\.|[^"\\])*)"|([^\]]+))\]"#
    )
    static let roundNodeLabelPattern = try? NSRegularExpression(
        pattern: #"\b([A-Za-z0-9_]+)\s*\((?:"((?:\\.|[^"\\])*)"|([^)]+))\)"#
    )

    private static let unsupportedFlowchartTokens: [String] = [
        "classdef",
        "class ",
        "style ",
        "linkstyle",
        "click ",
        "acctitle",
        "accdescr",
        ":::"
    ]

    static func split(
        diagram rawDiagram: String,
        profile: SplitProfile = .standard
    ) -> Result {
        let normalized = normalize(rawDiagram)
        let diagramMetrics = metrics(for: normalized)

        guard shouldAttemptSplit(metrics: diagramMetrics, profile: profile) else {
            return singleChunkResult(
                diagram: normalized,
                metrics: diagramMetrics,
                reason: "below_split_threshold"
            )
        }

        guard let candidate = parseConservativeFlowchartCandidate(diagram: normalized, profile: profile) else {
            return singleChunkResult(
                diagram: normalized,
                metrics: diagramMetrics,
                reason: "uncertain_or_unsupported_structure"
            )
        }

        let labelByIdentifier = collectNodeLabels(from: candidate.statements)
        let groupedStatements = groupStatements(
            candidate.statements,
            targetEdgesPerChunk: profile.targetEdgesPerChunk,
            maxCharactersPerChunk: profile.maxCharactersPerChunk
        )

        guard groupedStatements.count > 1 else {
            return singleChunkResult(
                diagram: normalized,
                metrics: diagramMetrics,
                reason: "single_group_after_split_pass"
            )
        }

        let chunks: [Chunk] = groupedStatements.enumerated().map { index, statements in
            var chunkLines = candidate.preambleLines
            chunkLines.append(candidate.headerLine)
            chunkLines.append(contentsOf: declarationLinesForChunk(
                statements: statements,
                labelByIdentifier: labelByIdentifier
            ))
            chunkLines.append(contentsOf: statements)
            let chunkDiagram = chunkLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let chunkMetrics = metrics(for: chunkDiagram)
            return Chunk(
                index: index,
                total: groupedStatements.count,
                title: chunkTitle(
                    for: statements,
                    index: index,
                    total: groupedStatements.count,
                    labelByIdentifier: labelByIdentifier
                ),
                diagram: chunkDiagram,
                metrics: chunkMetrics
            )
        }

        return Result(metrics: diagramMetrics, chunks: chunks, reason: "split_flowchart_edges")
    }

    // MARK: - Heuristics

    private static func shouldAttemptSplit(
        metrics: Metrics,
        profile: SplitProfile
    ) -> Bool {
        metrics.characterCount >= profile.maxCharactersBeforeSplit ||
        metrics.nonEmptyLineCount >= profile.maxNonEmptyLinesBeforeSplit ||
        metrics.edgeLineCount >= profile.maxEdgeLinesBeforeSplit
    }

    private struct ConservativeFlowchartCandidate {
        let preambleLines: [String]
        let headerLine: String
        let statements: [String]
    }

    private static func parseConservativeFlowchartCandidate(
        diagram: String,
        profile: SplitProfile
    ) -> ConservativeFlowchartCandidate? {
        let lines = diagram.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        guard let headerIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: splitEligibleHeaderPattern, options: .regularExpression) != nil
        }) else {
            return nil
        }

        var preambleLines: [String] = []
        if headerIndex > 0 {
            for raw in lines[..<headerIndex] {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || isCommentLine(trimmed) || isDirectiveLine(trimmed) {
                    preambleLines.append(raw)
                    continue
                }
                return nil
            }
        }

        let headerLine = lines[headerIndex].trimmingCharacters(in: .whitespaces)
        var statements: [String] = []
        var pendingComments: [String] = []
        var cursor = headerIndex + 1

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            cursor += 1
            if trimmed.isEmpty {
                continue
            }

            if isCommentLine(trimmed) {
                pendingComments.append(trimmed)
                continue
            }

            if profile.allowsSubgraphBlocks && isSubgraphStart(trimmed) {
                if !pendingComments.isEmpty {
                    statements.append(contentsOf: pendingComments)
                    pendingComments.removeAll()
                }

                var depth = 1
                var blockLines: [String] = [trimmed]

                while cursor < lines.count {
                    let subLine = lines[cursor].trimmingCharacters(in: .whitespaces)
                    cursor += 1
                    if subLine.isEmpty {
                        continue
                    }

                    if isCommentLine(subLine) {
                        blockLines.append(subLine)
                        continue
                    }

                    if isSubgraphStart(subLine) {
                        depth += 1
                        blockLines.append(subLine)
                        continue
                    }

                    if isSubgraphEnd(subLine) {
                        depth -= 1
                        blockLines.append(subLine)
                        if depth == 0 {
                            break
                        }
                        continue
                    }

                    guard isSplitSafeFlowchartEdge(subLine) || isStructuralLine(subLine, profile: profile) else {
                        return nil
                    }
                    blockLines.append(subLine)
                }

                guard depth == 0 else {
                    return nil
                }
                statements.append(blockLines.joined(separator: "\n"))
                continue
            }

            guard isSplitSafeFlowchartEdge(trimmed) || isStructuralLine(trimmed, profile: profile) else {
                return nil
            }

            if !pendingComments.isEmpty {
                statements.append(contentsOf: pendingComments)
                pendingComments.removeAll()
            }
            statements.append(trimmed)
        }

        guard !statements.isEmpty else {
            return nil
        }

        return ConservativeFlowchartCandidate(
            preambleLines: preambleLines,
            headerLine: headerLine,
            statements: statements
        )
    }

    private static func groupStatements(
        _ statements: [String],
        targetEdgesPerChunk: Int,
        maxCharactersPerChunk: Int
    ) -> [[String]] {
        var groups: [[String]] = []
        var currentGroup: [String] = []
        var currentChars = 0
        var currentEdgeCount = 0

        for statement in statements {
            let edgeIncrement = isCommentStatement(statement) ? 0 : edgeCount(in: statement)
            let nextChars = currentChars + statement.count + 1
            let exceedsEdgeTarget = !currentGroup.isEmpty && (currentEdgeCount + edgeIncrement > targetEdgesPerChunk)
            let exceedsCharTarget = !currentGroup.isEmpty && (nextChars > maxCharactersPerChunk)

            if exceedsEdgeTarget || exceedsCharTarget {
                groups.append(currentGroup)
                currentGroup = []
                currentChars = 0
                currentEdgeCount = 0
            }

            currentGroup.append(statement)
            currentChars += statement.count + 1
            currentEdgeCount += edgeIncrement
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups
    }

    private static func isSplitSafeFlowchartEdge(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if unsupportedFlowchartTokens.contains(where: { lowered.contains($0) }) {
            return false
        }
        return line.range(of: edgePattern, options: .regularExpression) != nil
    }

    private static func isStructuralLine(_ line: String, profile: SplitProfile) -> Bool {
        guard profile.allowsSubgraphBlocks else {
            return false
        }

        let lowered = line.lowercased()
        if isSubgraphStart(lowered) || isSubgraphEnd(lowered) {
            return true
        }
        return lowered.hasPrefix("direction ")
    }

    private static func isSubgraphStart(_ line: String) -> Bool {
        line.lowercased().hasPrefix("subgraph ")
    }

    private static func isSubgraphEnd(_ line: String) -> Bool {
        line.lowercased() == "end"
    }

    // MARK: - Metrics

    private static func metrics(for diagram: String) -> Metrics {
        let lines = diagram.components(separatedBy: "\n")
        let nonEmptyLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let characterCount = diagram.count
        let lineCount = lines.count
        let nonEmptyCount = nonEmptyLines.count
        let longestLineLength = lines.map(\.count).max() ?? 0
        let averageNonEmptyLineLength: Int = {
            guard nonEmptyCount > 0 else { return 0 }
            let total = nonEmptyLines.reduce(0) { $0 + $1.count }
            return total / nonEmptyCount
        }()
        let edgeLineCount = nonEmptyLines.reduce(0) { partial, line in
            partial + (line.range(of: edgePattern, options: .regularExpression) != nil ? 1 : 0)
        }

        return Metrics(
            characterCount: characterCount,
            lineCount: lineCount,
            nonEmptyLineCount: nonEmptyCount,
            longestLineLength: longestLineLength,
            averageNonEmptyLineLength: averageNonEmptyLineLength,
            edgeLineCount: edgeLineCount
        )
    }

    // MARK: - Helpers

    private static func singleChunkResult(diagram: String, metrics: Metrics, reason: String) -> Result {
        let chunk = Chunk(
            index: 0,
            total: 1,
            title: "Diagram",
            diagram: diagram,
            metrics: metrics
        )
        return Result(metrics: metrics, chunks: [chunk], reason: reason)
    }

    private static func normalize(_ rawDiagram: String) -> String {
        rawDiagram
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCommentLine(_ line: String) -> Bool {
        line.hasPrefix("%%")
    }

    static func isCommentStatement(_ statement: String) -> Bool {
        let lines = statement
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { isCommentLine($0) }
    }

    private static func edgeCount(in statement: String) -> Int {
        statement
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reduce(0) { partial, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else {
                    return partial
                }
                return partial + (line.range(of: edgePattern, options: .regularExpression) != nil ? 1 : 0)
            }
    }

    private static func isDirectiveLine(_ line: String) -> Bool {
        line.hasPrefix("%%{") && line.hasSuffix("}%%")
    }

}
