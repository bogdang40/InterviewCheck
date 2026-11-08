import Foundation

extension QuickAssistCallRecord {
    /// Full-field copy of this turn into another thread: resets the row id,
    /// mints a fresh turn id, applies the supplied identity, timing, and
    /// experiment fields, and preserves every other column verbatim. New
    /// columns added to the record get copied here once instead of in each
    /// thread-copy call site.
    func copiedInto(
        sessionId: String,
        threadId: String,
        startedAt: Date,
        modelTier: QuickAssistModelTier,
        experimentGroupId: String?,
        candidateLabel: String?,
        baseTurnId: String?,
        candidateRole: QuickAssistCandidateRole?
    ) -> QuickAssistCallRecord {
        QuickAssistCallRecord(
            id: nil,
            sessionId: sessionId,
            threadId: threadId,
            turnId: UUID().uuidString,
            provider: provider,
            model: model,
            startedAt: startedAt,
            completedAt: durationMs.map { startedAt.addingTimeInterval(Double($0) / 1000) },
            durationMs: durationMs,
            isFollowUp: isFollowUp,
            transcriptLength: transcriptLength,
            hasScreenshot: hasScreenshot,
            hasPreviousResponse: hasPreviousResponse,
            responseLength: responseLength,
            status: status,
            errorMessage: errorMessage,
            transcriptText: transcriptText,
            question: question,
            extraContext: extraContext,
            requestPayload: requestPayload,
            responseText: responseText,
            rawResponseText: rawResponseText,
            guardedResponseText: guardedResponseText,
            previousResponse: previousResponse,
            contextMode: contextMode,
            modelTier: modelTier,
            questionSource: questionSource,
            routeConfidence: routeConfidence,
            verificationStatus: verificationStatus,
            verificationConfidence: verificationConfidence,
            unsupportedClaimCount: unsupportedClaimCount,
            verificationMissingQuestions: verificationMissingQuestions,
            verificationSuggestedFollowUp: verificationSuggestedFollowUp,
            policyVersion: policyVersion,
            routeOverride: routeOverride,
            evidencePackManifest: evidencePackManifest,
            userFeedbackStatus: userFeedbackStatus,
            userFeedbackNote: userFeedbackNote,
            userFeedbackAt: userFeedbackAt,
            experimentGroupId: experimentGroupId,
            candidateLabel: candidateLabel,
            baseTurnId: baseTurnId,
            candidateRole: candidateRole
        )
    }
}
