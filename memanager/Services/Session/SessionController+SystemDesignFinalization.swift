import Foundation

extension SessionController {
    func finalizeSystemDesignResponse(
        _ response: MentorResponse,
        provider: AIProvider,
        providerType: AIProviderType,
        context: SessionContext,
        sessionID: UUID,
        requestID: UUID
    ) async -> (response: MentorResponse, report: SystemDesignCompletenessReport) {
        var finalResponse = response
        var completenessReport = SessionController.buildSystemDesignCompletenessReport(
            for: response,
            recoveryAttempted: false
        )
        let initialMissingSteps = completenessReport.incompleteSections.reduce(0) { total, section in
            total + section.missingStepCount
        }
        let initialCoherenceIssues = completenessReport.incompleteSections.reduce(0) { total, section in
            total + section.coherenceIssues.count
        }
        if initialCoherenceIssues > 0 {
            let details = completenessReport.incompleteSections
                .filter { !$0.coherenceIssues.isEmpty }
                .map { "\($0.id)=\($0.coherenceIssues.count)" }
                .joined(separator: ",")
            self.logger.logSystemDesignEvent(
                name: "progressive_coherence_issues_detected",
                details: details
            )
        }
        var recoveryOutcome = "not_needed"

        if !completenessReport.isComplete {
            recoveryOutcome = "attempted"
            self.logger.logSystemDesignEvent(
                name: "progressive_sections_incomplete",
                details: completenessReport.missingSummary
            )

            let completenessSnapshot = completenessReport
            await MainActor.run {
                guard self.acceptsSolveUpdate(sessionID: sessionID, requestID: requestID) else { return }
                self.systemDesignRecoveryInProgress = true
                self.systemDesignCompletenessReport = completenessSnapshot
            }

            // Bounded retry: recovery was single shot, so a recovery
            // response that itself came back incomplete just left the
            // orange banner up. Each attempt rebuilds the report and a
            // fresh targeted request from what is STILL missing; stop as
            // soon as the report is complete or attempts are exhausted.
            let maxRecoveryAttempts = 2
            for attempt in 1...maxRecoveryAttempts {
                guard !Task.isCancelled, !completenessReport.isComplete else { break }

                if let recoveredResponse = await attemptSystemDesignRecovery(
                    provider: provider,
                    context: context,
                    baseResponse: finalResponse,
                    report: completenessReport
                ) {
                    finalResponse = recoveredResponse
                }

                completenessReport = SessionController.buildSystemDesignCompletenessReport(
                    for: finalResponse,
                    recoveryAttempted: true
                )
                self.logger.logSystemDesignEvent(
                    name: "progressive_recovery_attempt_finished",
                    details: "attempt=\(attempt)/\(maxRecoveryAttempts), complete=\(completenessReport.isComplete)"
                )
            }

            self.logger.logSystemDesignEvent(
                name: "progressive_sections_after_recovery",
                details: completenessReport.missingSummary
            )

            let postRecoveryCoherenceIssues = completenessReport.incompleteSections.reduce(0) { total, section in
                total + section.coherenceIssues.count
            }
            if postRecoveryCoherenceIssues > 0 {
                let details = completenessReport.incompleteSections
                    .filter { !$0.coherenceIssues.isEmpty }
                    .map { "\($0.id)=\($0.coherenceIssues.count)" }
                    .joined(separator: ",")
                self.logger.logSystemDesignEvent(
                    name: "progressive_coherence_issues_after_recovery",
                    details: details
                )
            }
        }

        let shouldApplyVoiceGuard = self.settings.shouldApplyVoiceGuard(for: providerType)
        let normalized = shouldApplyVoiceGuard
            ? self.responseVoiceGuard.normalizeMentorResponse(
                finalResponse,
                systemDesignMode: true
            )
            : (
                response: finalResponse,
                report: VoiceNormalizationReport(
                    coachingDetected: false,
                    firstPersonBefore: false,
                    firstPersonAfter: false,
                    rewriteCount: 0,
                    bannedOpenerRewrites: 0,
                    leadInjected: false
                )
            )
        finalResponse = normalized.response
        if shouldApplyVoiceGuard {
            self.logVoiceNormalization(surface: .systemDesign, report: normalized.report)
        }
        completenessReport = SessionController.buildSystemDesignCompletenessReport(
            for: finalResponse,
            recoveryAttempted: recoveryOutcome != "not_needed"
        )

        let finalMissingSteps = completenessReport.incompleteSections.reduce(0) { total, section in
            total + section.missingStepCount
        }
        let finalCoherenceIssues = completenessReport.incompleteSections.reduce(0) { total, section in
            total + section.coherenceIssues.count
        }
        if recoveryOutcome == "attempted" {
            if finalMissingSteps == 0 && finalCoherenceIssues == 0 {
                if initialMissingSteps > 0 && initialCoherenceIssues > 0 {
                    recoveryOutcome = "missing_and_coherence_fixed"
                } else if initialCoherenceIssues > 0 {
                    recoveryOutcome = "coherence_fixed"
                } else {
                    recoveryOutcome = "missing_fixed"
                }
            } else {
                recoveryOutcome = "still_incomplete"
            }
        }
        self.logger.logSystemDesignEvent(
            name: "progressive_recovery_outcome",
            details: "status=\(recoveryOutcome), missingBefore=\(initialMissingSteps), missingAfter=\(finalMissingSteps), coherenceBefore=\(initialCoherenceIssues), coherenceAfter=\(finalCoherenceIssues)"
        )

        return (finalResponse, completenessReport)
    }
}
