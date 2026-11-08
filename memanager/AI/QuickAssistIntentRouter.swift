import Foundation

struct QuickAssistIntentResolution {
    let intent: QuickAssistIntent
    let confidence: Double
    let signals: [String]

    var reason: String {
        signals.joined(separator: ", ")
    }
}

final class QuickAssistIntentRouter {
    func routeIntent(
        question: String,
        transcript: String,
        extraContext: String,
        hasVisualEvidence: Bool,
        resolvedContext: QuickAssistContextResolver.ResolvedContext
    ) -> QuickAssistIntentResolution {
        let hasTextEvidence = [question, extraContext, transcript].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasVisualEvidence && !hasTextEvidence {
            return QuickAssistIntentResolution(
                intent: .walkthrough,
                confidence: 0.86,
                signals: ["fallback=screenshot_only_no_text"]
            )
        }

        let normalized = [question, extraContext, transcript]
            .joined(separator: " ")
            .lowercased()

        var signals: [String] = []
        var intent: QuickAssistIntent = .conversation
        var confidence = 0.55

        if hasAnyWord(in: normalized, terms: ["implementation brief", "project brief", "change plan", "plan this change", "which files", "relevant files", "codebase review", "implementation plan"]) {
            intent = .projectBrief
            confidence = 0.9
            signals.append("query=project_brief_terms")
        } else if resolvedContext.contextMode == .systemDesignContext {
            intent = .systemDesign
            confidence = 0.78
            signals.append("resolved_context=system_design")
        } else if resolvedContext.contextMode == .implementationContext {
            signals.append("resolved_context=implementation")
        }

        if intent != .projectBrief {
            if hasAnyWord(in: normalized, terms: ["architecture", "throughput", "latency", "partition", "load balancer", "replication", "availability"]) {
                intent = .systemDesign
                confidence = 0.9
                signals.append("query=system_design_terms")
            } else if hasAnyWord(in: normalized, terms: ["bug", "failing", "error", "exception", "stack trace", "broken", "incorrect", "fix"]) {
                intent = .debug
                confidence = 0.88
                signals.append("query=debug_terms")
            } else if hasAnyWord(in: normalized, terms: ["walk through", "step by step", "deep dive", "explain thoroughly", "why this works"]) {
                intent = .walkthrough
                confidence = 0.82
                signals.append("query=walkthrough_terms")
            } else if hasAnyWord(in: normalized, terms: ["clarify", "what should i ask", "assumption", "unknown requirement", "unclear"]) {
                intent = .clarify
                confidence = 0.77
                signals.append("query=clarify_terms")
            }
        }

        if signals.isEmpty {
            signals.append("default=conversation")
        }

        return QuickAssistIntentResolution(intent: intent, confidence: confidence, signals: signals)
    }

    private func hasAnyWord(in text: String, terms: [String]) -> Bool {
        terms.contains { term in
            guard !term.isEmpty else { return false }
            if term.contains(" ") {
                return text.contains(term)
            }

            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
