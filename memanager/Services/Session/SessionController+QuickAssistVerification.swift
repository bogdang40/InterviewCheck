import Foundation

extension SessionController {
    func runQuickAssistVerification(
        threadID: String,
        turnID: String,
        question: String,
        responseText: String,
        evidencePack: QuickAssistEvidencePack
    ) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let baseVerification = self.answerVerifier.verify(
                responseText: responseText,
                question: question,
                evidencePack: evidencePack
            )
            let verification = self.applyToolEvidenceReview(
                to: baseVerification,
                responseText: responseText,
                turnID: turnID
            )
            self.logger.updateQuickAssistCallVerification(
                threadId: threadID,
                turnId: turnID,
                verification: verification
            )
            await MainActor.run {
                guard self.activeQuickAssistThreadID == threadID else { return }
                let refreshed = self.workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID)
                self.cacheQuickAssistCallMetadata(refreshed)
                self.syncQuickAssistSelectedTurnMetadata()
                self.refreshWorkstreamTimeline()
                if self.settings.quickAssistAutoCompareEnabled,
                   let verifiedCall = refreshed.last(where: { $0.turnId == turnID }),
                   verifiedCall.candidateRole == nil,
                   (verifiedCall.routeConfidence ?? 1) < 0.62 ||
                    verifiedCall.verificationStatus == .needsReview ||
                    verifiedCall.verificationStatus == .failed {
                    Task { @MainActor in
                        await self.runQuickAssistExperiment()
                    }
                }
            }
        }
    }
    private func applyToolEvidenceReview(
        to verification: QuickAssistVerificationRecord,
        responseText: String,
        turnID: String
    ) -> QuickAssistVerificationRecord {
        let toolRecords = workstreamTimelineRepository.loadToolCalls(turnId: turnID)
        let toolTrace = toolTracePresenter.present(
            records: toolRecords,
            turnID: UUID(uuidString: turnID)
        )
        let review = toolBackedAnswerReviewer.review(responseText: responseText, trace: toolTrace)
        guard review.shouldMarkNeedsReview else { return verification }

        var missingQuestions = verification.missingQuestions
        if let reason = review.reason, !reason.isEmpty, !missingQuestions.contains(reason) {
            missingQuestions.append(reason)
        }

        let status: QuickAssistVerificationStatus = verification.status == .failed ? .failed : .needsReview
        return QuickAssistVerificationRecord(
            status: status,
            confidence: verification.confidence,
            unsupportedClaimCount: verification.unsupportedClaimCount,
            missingQuestions: missingQuestions,
            suggestedFollowUp: verification.suggestedFollowUp
                ?? "Regenerate with exact file citations, line references, and fenced code evidence."
        )
    }
}
