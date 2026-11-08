import Foundation

protocol QuickAssistAnswerVerifying {
    func verify(
        responseText: String,
        question: String,
        evidencePack: QuickAssistEvidencePack
    ) -> QuickAssistVerificationRecord
}

final class QuickAssistAnswerVerifier: QuickAssistAnswerVerifying {
    func verify(
        responseText: String,
        question: String,
        evidencePack: QuickAssistEvidencePack
    ) -> QuickAssistVerificationRecord {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            return QuickAssistVerificationRecord(
                status: .failed,
                confidence: nil,
                unsupportedClaimCount: 0,
                missingQuestions: ["No answer was produced for verification."],
                suggestedFollowUp: "Regenerate the answer with a direct response to the question."
            )
        }

        let evidenceScore = min(1.0, (
            (evidencePack.questionLength > 0 ? 0.35 : 0) +
            (evidencePack.transcriptLength > 80 ? 0.2 : 0) +
            (evidencePack.extraContextLength > 0 ? 0.1 : 0) +
            (evidencePack.relatedMemoryCount > 0 ? 0.15 : 0) +
            (evidencePack.screenshotCount > 0 ? 0.15 : 0) +
            (evidencePack.routeConfidence * 0.15)
        ))

        let unsupportedClaimCount = estimateUnsupportedClaimCount(
            responseText: trimmedResponse,
            question: question,
            evidencePack: evidencePack
        )
        let confidence = max(0.05, min(0.99, evidenceScore - (Double(unsupportedClaimCount) * 0.1)))
        let explicitNonAnswerResponse = isExplicitNonAnswerResponse(trimmedResponse)
        let nonAnswerLikeResponse = isNonAnswerLikeResponse(trimmedResponse)

        var missingQuestions: [String] = []
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missingQuestions.append("What exact question did the interviewer ask?")
        }
        if unsupportedClaimCount > 0 {
            missingQuestions.append("Can we validate \(unsupportedClaimCount) claim(s) against transcript or screenshot evidence?")
        }
        if evidencePack.transcriptLength == 0 && evidencePack.screenshotCount == 0 {
            missingQuestions.append("Do we have enough interview evidence to trust this answer?")
        }

        let suggestedFollowUp = missingQuestions.first

        let status: QuickAssistVerificationStatus
        if explicitNonAnswerResponse || (confidence < 0.22 && nonAnswerLikeResponse) {
            status = .failed
        } else if confidence < 0.68 || unsupportedClaimCount > 0 || !missingQuestions.isEmpty {
            status = .needsReview
        } else {
            status = .verified
        }

        return QuickAssistVerificationRecord(
            status: status,
            confidence: confidence,
            unsupportedClaimCount: unsupportedClaimCount,
            missingQuestions: missingQuestions,
            suggestedFollowUp: suggestedFollowUp
        )
    }

    private func isExplicitNonAnswerResponse(_ responseText: String) -> Bool {
        let normalized = responseText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        let explicitNonAnswerPhrases = [
            "i don't know",
            "i do not know",
            "not sure",
            "unsure",
            "no idea",
            "can't tell",
            "cannot tell"
        ]

        return wordCount <= 6 &&
            explicitNonAnswerPhrases.contains(where: normalized.hasPrefix)
    }

    private func isNonAnswerLikeResponse(_ responseText: String) -> Bool {
        let normalized = responseText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let shortResponseThreshold = 24
        let nonAnswerPhrases = [
            "need more context",
            "need additional context"
        ]

        return normalized.count <= shortResponseThreshold ||
            nonAnswerPhrases.contains(where: normalized.contains)
    }

    private func estimateUnsupportedClaimCount(
        responseText: String,
        question: String,
        evidencePack: QuickAssistEvidencePack
    ) -> Int {
        let strictTerms = ["always", "never", "guaranteed", "definitely", "must"]
        let responseLower = responseText.lowercased()
        let strictCount = strictTerms.reduce(into: 0) { partialResult, token in
            if responseLower.contains(token) {
                partialResult += 1
            }
        }
        let numericClaimCount = responseLower.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .count

        let lowEvidencePenalty = (evidencePack.transcriptLength < 40 && evidencePack.screenshotCount == 0) ? 1 : 0
        let questionPenalty = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0
        let total = strictCount + min(2, numericClaimCount / 4) + lowEvidencePenalty + questionPenalty
        return max(0, total)
    }
}
