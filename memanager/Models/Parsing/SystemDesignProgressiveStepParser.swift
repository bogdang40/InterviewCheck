import Foundation
import CryptoKit

/// Parses progressive design steps and mermaid diagrams inside
/// system design sections.
enum SystemDesignProgressiveStepParser {
    /// Stable identity for a step, derived from its section and final
    /// number. During streaming the section text is re-parsed as it grows;
    /// init-time random UUIDs gave every re-parse a brand new identity and
    /// forced SwiftUI to rebuild each step card (and its mermaid webview)
    /// per publish. Content derived ids let unchanged steps diff in place.
    private static func deterministicStepID(section: String, number: Int) -> UUID {
        let digest = Insecure.MD5.hash(data: Data("sd-step|\(section)|\(number)".utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
    private static let progressiveStepHeaderRegex = try? NSRegularExpression(
        pattern: #"(?m)^(?:#{2,6}\s*Step\s*(\d+)\s*(?::|-)\s*(.+?)\s*|\*\*\s*Step\s*(\d+)\s*(?::|-)\s*(.+?)\s*\*\*)$"#,
        options: [.caseInsensitive]
    )

    private static let progressiveStepHeaderPresenceRegex = try? NSRegularExpression(
        pattern: #"(?im)^\s*(?:#{2,6}\s*step\b|\*\*\s*step\b)"#,
        options: [.caseInsensitive]
    )

    static func parseProgressiveSteps(
        from raw: String,
        legacyTitle: String
    ) -> [ProgressiveDesignStep] {
        let hasExplicitStepHeaders = containsProgressiveStepHeaders(in: raw)
        let matches = extractProgressiveStepMatches(from: raw)
        if matches.isEmpty {
            if hasExplicitStepHeaders {
                SessionLogger.shared.logMermaidEvent(
                    name: "progressive_steps_omitted_no_valid_headers",
                    details: "section=\(legacyTitle)"
                )
                return []
            }
            return synthesizeLegacyStep(from: raw, title: legacyTitle)
        }

        var parsed: [(rawNumber: Int, step: ProgressiveDesignStep)] = []
        for match in matches {
            if let step = buildProgressiveStep(
                number: match.number,
                title: match.title,
                body: match.body,
                fallbackDecision: "\(legacyTitle) decision"
            ) {
                parsed.append((rawNumber: match.number, step: step))
            } else {
                MarkdownSectionGrammar.logMermaidEventThrottled(
                    name: "progressive_step_skipped_invalid",
                    details: "section=\(legacyTitle), rawStep=\(match.number)",
                    key: "progressive_step_skipped_invalid|\(legacyTitle)|\(match.number)",
                    sampleEvery: 40
                )
            }
        }

        var dedupedByRaw: [Int: (step: ProgressiveDesignStep, replaced: Bool)] = [:]
        var duplicateOverrideCount = 0
        for entry in parsed {
            if dedupedByRaw[entry.rawNumber] != nil {
                duplicateOverrideCount += 1
                dedupedByRaw[entry.rawNumber] = (step: entry.step, replaced: true)
            } else {
                dedupedByRaw[entry.rawNumber] = (step: entry.step, replaced: false)
            }
        }

        if duplicateOverrideCount > 0 {
            MarkdownSectionGrammar.logMermaidEventThrottled(
                name: "progressive_duplicate_step_overridden",
                details: "section=\(legacyTitle), overrides=\(duplicateOverrideCount)",
                key: "progressive_duplicate_step_overridden|\(legacyTitle)|\(duplicateOverrideCount)",
                sampleEvery: 15
            )
        }

        let orderedRawNumbers = dedupedByRaw.keys.sorted()
        let renumbered = orderedRawNumbers.enumerated().compactMap { index, rawNumber -> ProgressiveDesignStep? in
            guard let entry = dedupedByRaw[rawNumber] else { return nil }
            let step = entry.step
            return ProgressiveDesignStep(
                id: deterministicStepID(section: legacyTitle, number: index + 1),
                number: index + 1,
                title: step.title,
                reasoning: step.reasoning,
                decision: step.decision,
                tradeOff: step.tradeOff,
                buildsOn: step.buildsOn,
                diagramDelta: step.diagramDelta,
                whyNow: step.whyNow,
                wasOverriddenDuringMerge: entry.replaced,
                mermaidDiagram: step.mermaidDiagram
            )
        }

        if renumbered.isEmpty, hasExplicitStepHeaders {
            return []
        }

        return renumbered
    }

    private static func containsProgressiveStepHeaders(in raw: String) -> Bool {
        guard let regex = progressiveStepHeaderPresenceRegex else { return false }
        let range = NSRange(location: 0, length: (raw as NSString).length)
        return regex.firstMatch(in: raw, range: range) != nil
    }

    private static func extractProgressiveStepMatches(from raw: String) -> [(number: Int, title: String, body: String)] {
        guard let regex = progressiveStepHeaderRegex else { return [] }

        let nsString = raw as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: raw, range: fullRange)
        guard !matches.isEmpty else { return [] }

        var extracted: [(number: Int, title: String, body: String)] = []
        for (index, match) in matches.enumerated() {
            let markdownNumberRange = match.range(at: 1)
            let markdownTitleRange = match.range(at: 2)
            let boldNumberRange = match.range(at: 3)
            let boldTitleRange = match.range(at: 4)

            let numberRange = markdownNumberRange.location != NSNotFound
                ? markdownNumberRange
                : boldNumberRange
            let titleRange = markdownTitleRange.location != NSNotFound
                ? markdownTitleRange
                : boldTitleRange

            guard titleRange.location != NSNotFound else { continue }

            let rawNumber = numberRange.location != NSNotFound
                ? Int(nsString.substring(with: numberRange)) ?? (index + 1)
                : (index + 1)
            let title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)

            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsString.length
            guard bodyEnd >= bodyStart else { continue }

            let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            let body = nsString.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
            extracted.append((number: rawNumber, title: title, body: body))
        }

        return extracted
    }

    private static func buildProgressiveStep(
        number: Int,
        title: String,
        body: String,
        fallbackDecision: String
    ) -> ProgressiveDesignStep? {
        guard let diagram = extractMermaidDiagram(from: body),
              isLikelyValidMermaid(diagram) else {
            return nil
        }

        let stripped = stripMermaidBlocks(from: body)
        let decision = extractLabeledValue(from: stripped, labels: ["Decision"]) ?? fallbackDecision
        let tradeOff = extractLabeledValue(from: stripped, labels: ["Trade-off", "Tradeoff"])
        let buildsOn = extractLabeledValue(
            from: stripped,
            labels: [
                "Builds-on", "Builds on", "Builds upon", "Carries forward", "Inherits"
            ]
        )
        let diagramDelta = extractLabeledValue(
            from: stripped,
            labels: [
                "Diagram delta", "Diagram change", "Delta", "Change from previous", "What changed"
            ]
        )
        let whyNow = extractLabeledValue(
            from: stripped,
            labels: [
                "Why now", "Why this matters now", "Why this change now", "Justification"
            ]
        )
        var reasoning = stripLabeledLines(
            from: stripped,
            labels: [
                "Decision", "Trade-off", "Tradeoff",
                "Builds-on", "Builds on", "Builds upon", "Carries forward", "Inherits",
                "Diagram delta", "Diagram change", "Delta", "Change from previous", "What changed",
                "Why now", "Why this matters now", "Why this change now", "Justification"
            ]
        )
        if reasoning.isEmpty {
            reasoning = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Step \(number)"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProgressiveDesignStep(
            number: number,
            title: safeTitle,
            reasoning: reasoning,
            decision: decision,
            tradeOff: tradeOff,
            buildsOn: buildsOn,
            diagramDelta: diagramDelta,
            whyNow: whyNow,
            mermaidDiagram: diagram
        )
    }

    private static func synthesizeLegacyStep(from raw: String, title: String) -> [ProgressiveDesignStep] {
        guard let diagram = extractMermaidDiagram(from: raw),
              isLikelyValidMermaid(diagram) else {
            return []
        }

        let stripped = stripMermaidBlocks(from: raw)
        let decision = extractLabeledValue(from: stripped, labels: ["Decision"]) ?? "\(title) baseline"
        let tradeOff = extractLabeledValue(from: stripped, labels: ["Trade-off", "Tradeoff"])
        var reasoning = stripLabeledLines(
            from: stripped,
            labels: [
                "Decision", "Trade-off", "Tradeoff",
                "Builds-on", "Builds on", "Builds upon", "Carries forward", "Inherits",
                "Diagram delta", "Diagram change", "Delta", "Change from previous", "What changed",
                "Why now", "Why this matters now", "Why this change now", "Justification"
            ]
        )
        if reasoning.isEmpty {
            reasoning = stripped
        }

        return [
            ProgressiveDesignStep(
                id: deterministicStepID(section: title, number: 1),
                number: 1,
                title: "Baseline \(title)",
                reasoning: reasoning,
                decision: decision,
                tradeOff: tradeOff,
                buildsOn: nil,
                diagramDelta: nil,
                whyNow: nil,
                wasOverriddenDuringMerge: false,
                mermaidDiagram: diagram
            )
        ]
    }

    private static func isLikelyValidMermaid(_ diagram: String) -> Bool {
        let allowedPrefixes = [
            "flowchart", "graph", "sequencediagram", "erdiagram", "classdiagram",
            "statediagram", "journey", "gantt", "pie", "mindmap", "timeline",
            "gitgraph", "quadrantchart", "requirementdiagram", "c4context",
            "c4container", "c4component", "c4dynamic", "c4deployment"
        ]

        let lines = diagram.components(separatedBy: .newlines)
        guard let firstMeaningfulLine = lines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("%%") }) else {
            return false
        }

        let normalized = firstMeaningfulLine
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return allowedPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func extractLabeledValue(from text: String, labels: [String]) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = sanitizePotentialLabelLine(rawLine)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            for label in labels {
                let lowerLabel = label.lowercased()
                let colonPrefix = lowerLabel + ":"
                if lower.hasPrefix(colonPrefix) {
                    let value = String(line.dropFirst(colonPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        return value
                    }
                }

                let dashPrefix = lowerLabel + " -"
                if lower.hasPrefix(dashPrefix) {
                    let value = String(line.dropFirst(dashPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
    }

    private static func stripLabeledLines(from text: String, labels: [String]) -> String {
        let filtered = text.components(separatedBy: .newlines).filter { rawLine in
            let line = sanitizePotentialLabelLine(rawLine)
            guard !line.isEmpty else { return true }
            let lower = line.lowercased()
            return !labels.contains { label in
                let lowerLabel = label.lowercased()
                return lower.hasPrefix(lowerLabel + ":") || lower.hasPrefix(lowerLabel + " -")
            }
        }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizePotentialLabelLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("-") || cleaned.hasPrefix("*") {
            cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.replacingOccurrences(of: "**", with: "")
    }

    private static func stripStepHeaders(from text: String) -> String {
        guard let regex = progressiveStepHeaderRegex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractSectionDescription(from raw: String) -> String {
        var candidate = raw
        if let regex = progressiveStepHeaderRegex {
            let nsString = raw as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let firstStepHeader = regex.firstMatch(in: raw, range: range)
            if let firstStepHeader, firstStepHeader.range.location > 0 {
                let prefixRange = NSRange(location: 0, length: firstStepHeader.range.location)
                candidate = nsString.substring(with: prefixRange)
            } else if firstStepHeader != nil {
                candidate = ""
            }
        }

        let withoutMermaid = stripMermaidBlocks(from: candidate)
        return stripLabeledLines(
            from: stripStepHeaders(from: withoutMermaid),
            labels: [
                "Decision", "Trade-off", "Tradeoff",
                "Builds-on", "Builds on", "Builds upon", "Carries forward", "Inherits",
                "Diagram delta", "Diagram change", "Delta", "Change from previous", "What changed",
                "Why now", "Why this matters now", "Why this change now", "Justification"
            ]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
