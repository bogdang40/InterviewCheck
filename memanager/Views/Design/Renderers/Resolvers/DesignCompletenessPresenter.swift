import Foundation

/// A banner the design surface may show above its content.
struct DesignStatusBanner: Equatable {
    let tone: OverlayTone
    var title: String? = nil
    let message: String
    var systemImage: String? = nil
}

/// Maps the controller's completeness and recovery state onto banners, so
/// the settled view and the live view agree on wording and tone.
enum DesignCompletenessPresenter {
    /// Settled view: a report wins; recovery shows only before a report exists.
    static func settledBanner(report: SystemDesignCompletenessReport?, recoveryInProgress: Bool) -> DesignStatusBanner? {
        if let report {
            return reportBanner(report)
        }
        return recoveryInProgress ? recoveryBanner(scope: "steps") : nil
    }

    /// Live view: recovery in flight wins; a complete report needs no banner.
    static func liveBanner(report: SystemDesignCompletenessReport?, recoveryInProgress: Bool) -> DesignStatusBanner? {
        if recoveryInProgress {
            return recoveryBanner(scope: "sections")
        }
        guard let report, !report.isComplete else { return nil }
        return DesignStatusBanner(tone: .warning, title: "Generation incomplete", message: report.missingSummary)
    }

    /// The card level note for a section that missed its budget or coherence.
    static func sectionIssue(_ status: SystemDesignSectionCompleteness) -> DesignStatusBanner? {
        guard !status.isComplete else { return nil }
        var lines: [String] = []
        if status.missingStepCount > 0 {
            lines.append("Rendered \(status.actualStepCount) of \(status.expectedStepCount) required steps, missing \(status.missingStepCount).")
        }
        lines.append(contentsOf: status.coherenceIssues.prefix(2))
        return DesignStatusBanner(tone: .warning, title: "Incomplete section output", message: lines.joined(separator: " "))
    }

    private static func reportBanner(_ report: SystemDesignCompletenessReport) -> DesignStatusBanner {
        let suffix = report.recoveryAttempted ? " Recovery was attempted." : ""
        if report.isComplete {
            return DesignStatusBanner(
                tone: .success,
                message: "Progressive design output is complete.\(suffix)",
                systemImage: "checkmark.seal"
            )
        }
        return DesignStatusBanner(
            tone: .warning,
            title: "Incomplete progressive output",
            message: report.missingSummary + suffix
        )
    }

    private static func recoveryBanner(scope: String) -> DesignStatusBanner {
        DesignStatusBanner(
            tone: .info,
            message: "Recovering missing or weak progressive \(scope).",
            systemImage: "arrow.triangle.2.circlepath"
        )
    }
}
