import Foundation

struct QuickAssistRoutingPolicyDecision {
    let policyVersion: String
    let intentResolution: QuickAssistIntentResolution
    let contextModeOverride: QuickAssistContextMode?
    let modelTierOverride: QuickAssistModelTier?
    let routeOverrideIntent: QuickAssistIntent?
    let decisionVector: String
}

protocol QuickAssistRoutingPolicyEvaluating {
    func evaluate(
        baseIntentResolution: QuickAssistIntentResolution,
        resolvedContext: QuickAssistContextResolver.ResolvedContext,
        recentCalls: [QuickAssistCallRecord],
        questionSource: QuickAssistQuestionSource,
        isFollowUp: Bool,
        routeOverrideIntent: QuickAssistIntent?
    ) -> QuickAssistRoutingPolicyDecision
}

final class QuickAssistRoutingPolicyEngine: QuickAssistRoutingPolicyEvaluating {
    private let policyVersion = "qa_policy_v2"

    func evaluate(
        baseIntentResolution: QuickAssistIntentResolution,
        resolvedContext: QuickAssistContextResolver.ResolvedContext,
        recentCalls: [QuickAssistCallRecord],
        questionSource: QuickAssistQuestionSource,
        isFollowUp: Bool,
        routeOverrideIntent: QuickAssistIntent?
    ) -> QuickAssistRoutingPolicyDecision {
        var selectedIntent = baseIntentResolution.intent
        var confidence = min(max(baseIntentResolution.confidence, 0), 1)
        var signals = baseIntentResolution.signals
        var contextModeOverride: QuickAssistContextMode?
        var tierOverride: QuickAssistModelTier?

        let recent = Array(recentCalls.suffix(6))
        let failureCount = recent.filter { $0.status == "error" }.count
        let successfulDurations = recent
            .filter { $0.status == "success" }
            .compactMap(\.durationMs)
        let avgDurationMs: Int? = successfulDurations.isEmpty
            ? nil
            : (successfulDurations.reduce(0, +) / successfulDurations.count)

        if let overrideIntent = routeOverrideIntent {
            selectedIntent = overrideIntent
            confidence = 1
            signals.append("policy=manual_override:\(overrideIntent.rawValue)")
        } else {
            if questionSource == .auto && selectedIntent == .conversation {
                selectedIntent = .walkthrough
                confidence = max(confidence, 0.78)
                signals.append("policy=auto_question_prefers_walkthrough")
            }

            if failureCount >= 2 {
                tierOverride = .deep
                confidence = min(1, confidence + 0.08)
                signals.append("policy=failure_burst:\(failureCount)")
            } else if let avgDurationMs, avgDurationMs > 16_000 {
                tierOverride = .fast
                signals.append("policy=latency_relief:\(avgDurationMs)ms")
            }

            if isFollowUp, resolvedContext.contextMode != .conversation {
                contextModeOverride = resolvedContext.contextMode
                signals.append("policy=follow_up_context:\(resolvedContext.contextMode.rawValue)")
            }
        }

        let intentResolution = QuickAssistIntentResolution(
            intent: selectedIntent,
            confidence: confidence,
            signals: signals
        )

        let decisionVector = [
            "base_intent=\(baseIntentResolution.intent.rawValue)",
            "selected_intent=\(selectedIntent.rawValue)",
            "override=\(routeOverrideIntent?.rawValue ?? "none")",
            "recent_failures=\(failureCount)",
            "recent_avg_duration_ms=\(avgDurationMs.map(String.init) ?? "n/a")",
            "mode_override=\(contextModeOverride?.rawValue ?? "none")",
            "tier_override=\(tierOverride?.rawValue ?? "none")",
            "confidence=\(String(format: "%.2f", confidence))"
        ].joined(separator: ",")

        return QuickAssistRoutingPolicyDecision(
            policyVersion: policyVersion,
            intentResolution: intentResolution,
            contextModeOverride: contextModeOverride,
            modelTierOverride: tierOverride,
            routeOverrideIntent: routeOverrideIntent,
            decisionVector: decisionVector
        )
    }
}
