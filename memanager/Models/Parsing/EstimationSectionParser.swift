import Foundation

/// Parses the Estimation section: progressive steps plus `Metric: value
/// (formula)` rows, the parseable shape the v2 prompt demands for back of
/// the envelope figures.
enum EstimationSectionParser {
    /// `- Write QPS: about 3,500 (150M x 2 / 86,400)` or without the bullet
    /// or formula. The metric name must not be one of the step block labels.
    private static let metricLineRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s*)?([A-Za-z][A-Za-z0-9 /%()+-]{1,60}?):\s*([^\n(]+?)(?:\(([^)\n]+)\))?\s*$"#,
        options: [.anchorsMatchLines]
    )

    /// Step block labels and control lines that must never become metrics.
    private static let excludedNames: Set<String> = [
        "builds-on", "builds on", "builds upon", "carries forward", "inherits",
        "diagram delta", "diagram change", "delta", "change from previous", "what changed",
        "why now", "why this matters now", "why this change now", "justification",
        "decision", "trade-off", "tradeoff", "step"
    ]

    static func parseEstimation(from text: String) -> EstimationBlock? {
        let raw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "estimation"),
            in: text
        )
        guard let raw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Estimation")
        let metrics = parseMetrics(from: raw)
        guard !steps.isEmpty || !metrics.isEmpty else { return nil }

        return EstimationBlock(metrics: metrics, steps: steps)
    }

    static func parseMetrics(from raw: String) -> [EstimationMetric] {
        guard let regex = metricLineRegex else { return [] }

        // Strip mermaid fences so diagram labels never read as metrics.
        let withoutDiagrams = stripMermaidFences(from: raw)
        let nsString = withoutDiagrams as NSString
        var metrics: [EstimationMetric] = []

        for match in regex.matches(in: withoutDiagrams, range: NSRange(location: 0, length: nsString.length)) {
            let name = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let lowered = name.lowercased()
            guard !excludedNames.contains(lowered),
                  !lowered.hasPrefix("step ") else {
                continue
            }
            let value = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            // A metric row must carry at least one digit somewhere, or it is
            // prose with a colon.
            let formula = match.range(at: 3).location != NSNotFound
                ? nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                : nil
            guard value.contains(where: \.isNumber) || formula?.contains(where: \.isNumber) == true else {
                continue
            }
            metrics.append(EstimationMetric(name: name, value: value, formula: formula))
        }

        return metrics
    }

    private static func stripMermaidFences(from text: String) -> String {
        guard let fenceRegex = try? NSRegularExpression(
            pattern: #"^[ ]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ ]{0,3}\1[ ]*$"#,
            options: [.anchorsMatchLines]
        ) else {
            return text
        }
        let nsString = text as NSString
        return fenceRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        )
    }
}
