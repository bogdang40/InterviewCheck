import Foundation

final class QuickAssistContextResolver {

    struct ResolvedContext {
        let contextMode: QuickAssistContextMode
        let sectionContext: String
        let solveHistorySummary: String?
        let inferredComplexity: QuickAssistComplexity
        let suggestedModelTier: QuickAssistModelTier
        let tokenBudget: Int?
    }

    func resolve(
        currentSection: MentorResponse.Section,
        solveMode: SolveMode,
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?,
        transcript: String,
        question: String,
        extraContext: String
    ) -> ResolvedContext {
        let contextMode = inferContextMode(
            currentSection: currentSection,
            solveMode: solveMode,
            response: response,
            parsedSystemDesign: parsedSystemDesign
        )

        let sectionContext = buildSectionContext(
            for: contextMode,
            response: response,
            parsedSystemDesign: parsedSystemDesign
        )

        let solveHistorySummary = buildSolveHistorySummary(
            solveMode: solveMode,
            response: response,
            parsedSystemDesign: parsedSystemDesign
        )

        let complexity = inferComplexity(
            transcript: transcript,
            question: question,
            contextMode: contextMode,
            hasSolveResponse: response != nil
        )

        let tier = suggestModelTier(for: complexity)
        let budget: Int? = nil

        return ResolvedContext(
            contextMode: contextMode,
            sectionContext: sectionContext,
            solveHistorySummary: solveHistorySummary,
            inferredComplexity: complexity,
            suggestedModelTier: tier,
            tokenBudget: budget
        )
    }

    // MARK: - Context Mode Inference

    private func inferContextMode(
        currentSection: MentorResponse.Section,
        solveMode: SolveMode,
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?
    ) -> QuickAssistContextMode {
        guard response != nil else {
            return .conversation
        }

        switch currentSection {
        case .implementation:
            let hasImplementation = !(response?.implementation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasImplementation ? .implementationContext : .conversation

        case .systemDesign:
            let hasDesign = parsedSystemDesign?.hasContent == true ||
                !(response?.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasDesign ? .systemDesignContext : .conversation

        case .problem, .clarifyingQuestions:
            return .conversation

        case .tests, .complexity:
            let hasImplementation = !(response?.implementation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasImplementation ? .implementationContext : .conversation
        }
    }

    // MARK: - Section Context Building

    private func buildSectionContext(
        for mode: QuickAssistContextMode,
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?
    ) -> String {
        switch mode {
        case .conversation:
            return ""
        case .implementationContext:
            return buildImplementationContext(response: response)
        case .systemDesignContext:
            return buildSystemDesignContext(response: response, parsedSystemDesign: parsedSystemDesign)
        case .allSectionsContext:
            return buildAllSectionsContext(response: response, parsedSystemDesign: parsedSystemDesign)
        }
    }

    private func buildImplementationContext(response: MentorResponse?) -> String {
        guard let response else { return "" }
        var sections: [String] = ["IMPLEMENTATION CONTEXT FROM PREVIOUS SOLVE"]

        appendSection(title: "Problem", content: response.problem, into: &sections)
        appendSection(title: "Implementation", content: response.implementation, into: &sections)
        appendSection(title: "Tests", content: response.tests, into: &sections)
        appendSection(title: "Complexity", content: response.complexity, into: &sections)

        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }

    private func buildSystemDesignContext(
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?
    ) -> String {
        var sections: [String] = ["SYSTEM DESIGN CONTEXT FROM PREVIOUS SOLVE"]

        if let structured = parsedSystemDesign, structured.hasContent {
            appendSection(title: "Structured Design Context", content: structured.rawContent, into: &sections)
        }

        if let systemDesign = response?.systemDesign {
            appendSection(title: "System Design", content: systemDesign, into: &sections)
        }

        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }

    private func buildAllSectionsContext(
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?
    ) -> String {
        guard let response else { return "" }
        var sections: [String] = ["ALL SECTIONS CONTEXT FROM PREVIOUS SOLVE"]

        appendSection(title: "Problem", content: response.problem, into: &sections)
        appendSection(title: "Clarifying Questions", content: response.clarifyingQuestions, into: &sections)
        appendSection(title: "Implementation", content: response.implementation, into: &sections)
        appendSection(title: "Tests", content: response.tests, into: &sections)
        appendSection(title: "Complexity", content: response.complexity, into: &sections)

        if let structured = parsedSystemDesign, structured.hasContent {
            appendSection(title: "Structured Design Context", content: structured.rawContent, into: &sections)
        }

        appendSection(title: "System Design", content: response.systemDesign, into: &sections)
        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }

    private func appendSection(title: String, content: String, into sections: inout [String]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sections.append("\(title):\n\(trimmed)")
    }

    // MARK: - Solve History Summary

    private func buildSolveHistorySummary(
        solveMode: SolveMode,
        response: MentorResponse?,
        parsedSystemDesign: SystemDesignContent?
    ) -> String? {
        guard let response else { return nil }

        switch solveMode {
        case .algorithm:
            return buildAlgorithmSummary(response: response)
        case .systemDesign:
            return buildDesignSummary(response: response, parsedSystemDesign: parsedSystemDesign)
        }
    }

    private func buildAlgorithmSummary(response: MentorResponse) -> String? {
        var parts: [String] = []

        let problem = response.problem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !problem.isEmpty {
            let truncated = String(problem.prefix(300))
            parts.append("Problem: \(truncated)")
        }

        let complexity = response.complexity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !complexity.isEmpty {
            let truncated = String(complexity.prefix(200))
            parts.append("Complexity: \(truncated)")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func buildDesignSummary(
        response: MentorResponse,
        parsedSystemDesign: SystemDesignContent?
    ) -> String? {
        var parts: [String] = []

        if let structured = parsedSystemDesign {
            if let reqs = structured.requirements {
                let reqSummary = (reqs.functional + reqs.nonFunctional).prefix(5).joined(separator: "; ")
                if !reqSummary.isEmpty {
                    parts.append("Requirements: \(String(reqSummary.prefix(300)))")
                }
            }
            if let arch = structured.architecture {
                let archSummary = arch.description
                if !archSummary.isEmpty {
                    parts.append("Architecture: \(String(archSummary.prefix(300)))")
                }
            }
        }

        guard !parts.isEmpty else {
            let rawDesign = response.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawDesign.isEmpty { return nil }
            return "Design summary: \(String(rawDesign.prefix(500)))"
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Complexity Inference

    private func inferComplexity(
        transcript: String,
        question: String,
        contextMode: QuickAssistContextMode,
        hasSolveResponse: Bool
    ) -> QuickAssistComplexity {
        let combined = (transcript + " " + question).lowercased()
        let wordCount = combined.split(separator: " ").count

        let deepSignals = [
            "walk through", "walk me through", "step by step", "in depth",
            "explain thoroughly", "deep dive", "detailed", "architecture",
            "design", "implement", "trade-off", "trade off"
        ]
        let lightSignals = [
            "quick", "briefly", "short", "what is", "what's the",
            "time complexity", "space complexity", "concise"
        ]

        let hasDeepSignal = deepSignals.contains { combined.contains($0) }
        let hasLightSignal = lightSignals.contains { combined.contains($0) }

        if hasLightSignal && !hasDeepSignal {
            return .light
        }

        if hasDeepSignal {
            return .deep
        }

        switch contextMode {
        case .implementationContext, .systemDesignContext, .allSectionsContext:
            return wordCount > 50 ? .deep : .moderate
        case .conversation:
            return .moderate
        }
    }

    // MARK: - Model Tier Suggestion

    private func suggestModelTier(
        for complexity: QuickAssistComplexity
    ) -> QuickAssistModelTier {
        switch complexity {
        case .light:
            return .fast
        case .moderate, .deep:
            return .deep
        }
    }
}
