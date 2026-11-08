import Foundation

// MARK: - Protocol

protocol CrossSessionCoachEvaluating {
    func evaluate(report: SkillProgressionReport, sessionId: String) -> [CoachFindingRecord]
}

// MARK: - Implementation

/// Produces coach findings for regressing trends and recurring weak spots
/// across multiple sessions. Follows the same finding pattern as
/// `ProactiveFailureCoachEngine` but operates on cross-session data.
final class CrossSessionCoachEvaluator: CrossSessionCoachEvaluating {

    func evaluate(report: SkillProgressionReport, sessionId: String) -> [CoachFindingRecord] {
        guard !report.isEmpty else { return [] }

        var findings: [CoachFindingRecord] = []

        findings.append(contentsOf: findingsForRegressingTrends(report: report, sessionId: sessionId))
        findings.append(contentsOf: findingsForRecurringWeakSpots(report: report, sessionId: sessionId))

        return findings
    }

    // MARK: - Regressing Trends

    private func findingsForRegressingTrends(
        report: SkillProgressionReport,
        sessionId: String
    ) -> [CoachFindingRecord] {
        report.trends
            .filter { $0.direction == .regressing }
            .map { trend in
                CoachFindingRecord(
                    sessionId: sessionId,
                    threadId: nil,
                    issueType: .crossSessionRegression,
                    severity: trend.magnitude > 0.1 ? .warning : .info,
                    title: "\(displayName(for: trend.metric)) regressing",
                    message: "\(displayName(for: trend.metric)) has been declining over "
                        + "the last \(trend.snapshotCount) sessions "
                        + "(magnitude: \(String(format: "%.2f", trend.magnitude))).",
                    suggestedQuestion: suggestedQuestion(for: trend.metric),
                    suggestedContext: "Cross-session trend analysis detected a regression pattern.",
                    evidence: [
                        CoachEvidenceItem(label: "metric", value: trend.metric),
                        CoachEvidenceItem(label: "direction", value: trend.direction.rawValue),
                        CoachEvidenceItem(
                            label: "magnitude",
                            value: String(format: "%.3f", trend.magnitude)
                        ),
                        CoachEvidenceItem(label: "sessions", value: "\(trend.snapshotCount)")
                    ],
                    dedupeKey: "cross_session_\(trend.metric)_regressing"
                )
            }
    }

    // MARK: - Recurring Weak Spots

    private func findingsForRecurringWeakSpots(
        report: SkillProgressionReport,
        sessionId: String
    ) -> [CoachFindingRecord] {
        guard !report.recurringWeakSpots.isEmpty else { return [] }

        let spotLabels = report.recurringWeakSpots.map(\.displayLabel).joined(separator: ", ")

        return [
            CoachFindingRecord(
                sessionId: sessionId,
                threadId: nil,
                issueType: .crossSessionRegression,
                severity: .warning,
                title: "Recurring weak spots detected",
                message: "The following drill types appear in 3+ of the last "
                    + "\(report.snapshots.count) sessions: \(spotLabels). "
                    + "Consider dedicated practice in these areas.",
                suggestedQuestion: "How can I improve my \(report.recurringWeakSpots.first?.displayLabel ?? "weak") areas?",
                suggestedContext: "Recurring weak spots from cross-session analysis.",
                evidence: report.recurringWeakSpots.map {
                    CoachEvidenceItem(label: "recurring_kind", value: $0.rawValue)
                },
                dedupeKey: "cross_session_recurring_weak_spots"
            )
        ]
    }

    // MARK: - Display Helpers

    private func displayName(for metric: String) -> String {
        switch metric {
        case "verification_rate": return "Verification rate"
        case "unsupported_claim_density": return "Unsupported claim density"
        case "coach_finding_frequency": return "Coach finding frequency"
        case "average_latency": return "Average response latency"
        default: return metric
        }
    }

    private func suggestedQuestion(for metric: String) -> String {
        switch metric {
        case "verification_rate":
            return "How can I ground my answers with stronger evidence?"
        case "unsupported_claim_density":
            return "What claims in my responses lack supporting evidence?"
        case "coach_finding_frequency":
            return "What patterns keep triggering system alerts?"
        case "average_latency":
            return "How can I respond faster without losing quality?"
        default:
            return "How can I improve in this area?"
        }
    }
}
