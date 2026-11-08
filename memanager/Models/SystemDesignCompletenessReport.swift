import Foundation

struct SystemDesignSectionExpectation: Identifiable {
    let id: String
    let title: String
    let expectedStepCount: Int

    /// Derived from the blueprint's PROMPT ACTIVE sections: the completeness
    /// report judges against exactly what the prompt demanded, never against
    /// sections that exist in the taxonomy but are not yet requested.
    static let all: [SystemDesignSectionExpectation] = SystemDesignBlueprint.promptActiveSections.map {
        SystemDesignSectionExpectation(id: $0.id, title: $0.title, expectedStepCount: $0.expectedStepCount)
    }

    static func forSection(_ id: String) -> SystemDesignSectionExpectation? {
        all.first { $0.id == id }
    }
}

struct SystemDesignSectionCompleteness: Identifiable {
    let id: String
    let title: String
    let expectedStepCount: Int
    let actualStepCount: Int
    let coherenceIssues: [String]

    var missingStepCount: Int {
        max(0, expectedStepCount - actualStepCount)
    }

    var hasRequiredSteps: Bool {
        actualStepCount >= expectedStepCount
    }

    var qualityIssueCount: Int {
        coherenceIssues.count
    }

    var isComplete: Bool {
        hasRequiredSteps && coherenceIssues.isEmpty
    }
}

struct SystemDesignCompletenessReport {
    let generatedAt: Date
    let recoveryAttempted: Bool
    let sections: [SystemDesignSectionCompleteness]

    var isComplete: Bool {
        sections.allSatisfy { $0.isComplete }
    }

    var incompleteSections: [SystemDesignSectionCompleteness] {
        sections.filter { !$0.isComplete }
    }

    func status(for sectionID: String) -> SystemDesignSectionCompleteness? {
        sections.first { $0.id == sectionID }
    }

    var missingSummary: String {
        let incomplete = incompleteSections
        guard !incomplete.isEmpty else {
            return "All design sections meet progressive step and coherence requirements."
        }
        return incomplete.map { section in
            var summary = "\(section.title): \(section.actualStepCount)/\(section.expectedStepCount)"
            if !section.coherenceIssues.isEmpty {
                summary += " + \(section.coherenceIssues.count) coherence issue"
                if section.coherenceIssues.count > 1 {
                    summary += "s"
                }
            }
            return summary
        }
            .joined(separator: ", ")
    }

    static func from(
        content: SystemDesignContent,
        recoveryAttempted: Bool
    ) -> SystemDesignCompletenessReport {
        let sections = SystemDesignSectionExpectation.all.map { expectation in
            let steps = content.progressiveSteps(for: expectation.id)
            return SystemDesignSectionCompleteness(
                id: expectation.id,
                title: expectation.title,
                expectedStepCount: expectation.expectedStepCount,
                actualStepCount: steps.count,
                coherenceIssues: evaluateCoherenceIssues(for: steps)
            )
        }

        return SystemDesignCompletenessReport(
            generatedAt: Date(),
            recoveryAttempted: recoveryAttempted,
            sections: sections
        )
    }

    private static func evaluateCoherenceIssues(for steps: [ProgressiveDesignStep]) -> [String] {
        guard !steps.isEmpty else { return [] }

        var issues: [String] = []

        for (index, step) in steps.enumerated() {
            let textCorpus = [
                step.reasoning,
                step.decision,
                step.tradeOff ?? "",
                step.buildsOn ?? "",
                step.diagramDelta ?? "",
                step.whyNow ?? ""
            ].joined(separator: " ")

            let textIdentifiers = extractTextIdentifiers(from: textCorpus)
            let diagramIdentifiers = extractMermaidIdentifiers(from: step.mermaidDiagram)
            if !diagramIdentifiers.isEmpty,
               !textIdentifiers.isEmpty,
               textIdentifiers.intersection(diagramIdentifiers).isEmpty {
                issues.append("Step \(step.number) text does not reference diagram elements.")
            }

            guard index > 0 else { continue }
            let previous = steps[index - 1]
            let previousIdentifiers = extractMermaidIdentifiers(from: previous.mermaidDiagram)
            let sharedIdentifiers = previousIdentifiers.intersection(diagramIdentifiers)
            let hasExplicitProgression = hasProgressiveNarration(step)
            if !hasExplicitProgression {
                issues.append("Step \(step.number) is missing an explicit build-on explanation.")
            }

            if !sharedIdentifiers.isEmpty,
               !textIdentifiers.isEmpty,
               textIdentifiers.intersection(sharedIdentifiers).isEmpty {
                issues.append("Step \(step.number) does not reference carried-forward elements from step \(previous.number).")
            }

            if sharedIdentifiers.isEmpty, !hasExplicitProgression {
                issues.append("Step \(step.number) diagram does not clearly connect to step \(previous.number).")
            }

            if issues.count >= 10 {
                break
            }
        }

        // Ten instead of three: the recovery request is built from these
        // issues, and the old cap made recovery under-report on badly
        // degraded sections (the UI still shows only the first two).
        return Array(issues.prefix(10))
    }

    private static func hasProgressiveNarration(_ step: ProgressiveDesignStep) -> Bool {
        if let buildsOn = step.buildsOn, !buildsOn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let diagramDelta = step.diagramDelta, !diagramDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        let narrative = step.reasoning.lowercased()
        let cues = [
            "compared to",
            "compared with",
            "build on",
            "builds on",
            "extend",
            "extends",
            "add",
            "introduce",
            "previous step",
            "from step",
            "evolve",
            "increment"
        ]

        return cues.contains { narrative.contains($0) }
    }

    private static func extractTextIdentifiers(from text: String) -> Set<String> {
        normalizedTokens(from: text)
    }

    private static func extractMermaidIdentifiers(from diagram: String) -> Set<String> {
        let lines = diagram.components(separatedBy: .newlines)
        guard let firstMeaningfulLine = lines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("%%") }) else {
            return []
        }

        let kind = firstMeaningfulLine
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        if kind.hasPrefix("flowchart") || kind.hasPrefix("graph") {
            let ids = extractFlowchartIdentifiers(from: diagram)
            return ids.isEmpty ? normalizedTokens(from: diagram) : ids
        }
        if kind.hasPrefix("sequencediagram") {
            let ids = extractSequenceDiagramIdentifiers(from: diagram)
            return ids.isEmpty ? normalizedTokens(from: diagram) : ids
        }
        if kind.hasPrefix("erdiagram") {
            let ids = extractERDiagramIdentifiers(from: diagram)
            return ids.isEmpty ? normalizedTokens(from: diagram) : ids
        }

        return normalizedTokens(from: diagram)
    }

    private static func extractFlowchartIdentifiers(from diagram: String) -> Set<String> {
        var identifiers: Set<String> = []

        let nodeIdPattern = #"(?m)\b([A-Za-z][A-Za-z0-9_]*)\s*(?=\[|\(|\{)"#
        let relationshipNodePattern = #"(?m)\b([A-Za-z][A-Za-z0-9_]*)\b"#
        let labelPatterns = [
            #"\[([^\]]+)\]"#,
            #"\(([^)]+)\)"#,
            #"\{([^}]+)\}"#
        ]

        identifiers.formUnion(extractRegexGroupMatches(pattern: nodeIdPattern, in: diagram))
        identifiers.formUnion(extractRegexGroupMatches(pattern: relationshipNodePattern, in: diagram))
        for pattern in labelPatterns {
            for label in extractRegexGroupMatches(pattern: pattern, in: diagram) {
                identifiers.formUnion(normalizedTokens(from: label))
            }
        }

        let flowchartKeywords: Set<String> = [
            "flowchart", "graph", "lr", "rl", "tb", "bt", "subgraph", "end",
            "style", "class", "classdef", "linkstyle"
        ]
        return identifiers.filter { !flowchartKeywords.contains($0) }
    }

    private static func extractSequenceDiagramIdentifiers(from diagram: String) -> Set<String> {
        var identifiers: Set<String> = []

        let participantPattern = #"(?im)^\s*participant\s+([A-Za-z][A-Za-z0-9_]*)(?:\s+as\s+([^\n]+))?"#
        let actorPattern = #"(?m)\b([A-Za-z][A-Za-z0-9_]*)\s*[-]{1,2}[>]{1,2}"#

        identifiers.formUnion(extractRegexGroupMatches(pattern: participantPattern, in: diagram, groups: [1]))
        for alias in extractRegexGroupMatches(pattern: participantPattern, in: diagram, groups: [2]) {
            identifiers.formUnion(normalizedTokens(from: alias))
        }
        identifiers.formUnion(extractRegexGroupMatches(pattern: actorPattern, in: diagram))

        let sequenceKeywords: Set<String> = [
            "sequencediagram", "participant", "actor", "note", "over", "autonumber",
            "loop", "alt", "else", "opt", "par", "and", "break", "critical", "end"
        ]
        return identifiers.filter { !sequenceKeywords.contains($0) }
    }

    private static func extractERDiagramIdentifiers(from diagram: String) -> Set<String> {
        var identifiers: Set<String> = []

        let entityBlockPattern = #"(?im)^\s*([A-Za-z][A-Za-z0-9_]*)\s*\{"#
        let relationshipPattern = #"(?m)\b([A-Za-z][A-Za-z0-9_]*)\s+[|o}{\-.]+[-.]*[|o}{\-.]*\s+([A-Za-z][A-Za-z0-9_]*)\b"#

        identifiers.formUnion(extractRegexGroupMatches(pattern: entityBlockPattern, in: diagram))
        identifiers.formUnion(extractRegexGroupMatches(pattern: relationshipPattern, in: diagram, groups: [1, 2]))

        let erKeywords: Set<String> = ["erdiagram", "int", "string", "float", "bool", "date"]
        return identifiers.filter { !erKeywords.contains($0) }
    }

    private static func extractRegexGroupMatches(
        pattern: String,
        in text: String,
        groups: [Int] = [1]
    ) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        var matchesSet: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            for group in groups where group < match.numberOfRanges {
                let groupRange = match.range(at: group)
                guard groupRange.location != NSNotFound else { continue }
                let value = nsText.substring(with: groupRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    matchesSet.insert(value.lowercased())
                }
            }
        }

        return matchesSet
    }

    private static func normalizedTokens(from text: String) -> Set<String> {
        let lower = text.lowercased()
        let split = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "into", "from", "then",
            "step", "flowchart", "graph", "sequence", "diagram", "node", "edge",
            "decision", "trade", "off", "none", "why", "now", "builds", "on",
            "api", "db", "service", "fromstep"
        ]

        return Set(
            split
                .map(String.init)
                .map { token in
                    token.trimmingCharacters(in: CharacterSet.decimalDigits)
                }
                .filter { token in
                    token.count >= 3 && !stopWords.contains(token)
                }
        )
    }
}

/// Functional and non-functional requirements
