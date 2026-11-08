import Foundation

struct PracticeAttemptEvaluation: Equatable {
    let grade: PracticeGrade
    let confidence: Int
    let feedback: String
    let attemptTranscript: String
}

protocol PracticeAttemptGrading {
    func evaluate(card: PracticeCard, attemptTranscript: String) -> PracticeAttemptEvaluation
}

/// Offline grader for spoken practice attempts. It intentionally mirrors the
/// app's evidence posture: empty attempts fail, claims need overlap with the
/// card's ideal reasoning, and the feedback names the missing anchor instead
/// of giving generic encouragement.
struct PracticeAttemptGrader: PracticeAttemptGrading {
    func evaluate(card: PracticeCard, attemptTranscript: String) -> PracticeAttemptEvaluation {
        let attempt = attemptTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attempt.isEmpty else {
            return PracticeAttemptEvaluation(
                grade: .blackout,
                confidence: 95,
                feedback: "No spoken attempt was recorded for this card.",
                attemptTranscript: attempt
            )
        }

        let expectedTokens = Self.tokens(from: [
            card.prompt,
            card.idealReasoning,
            card.transcriptSnippet
        ].joined(separator: " "))
        let attemptTokens = Set(Self.tokens(from: attempt))
        let overlap = expectedTokens.filter { attemptTokens.contains($0) }
        let overlapRatio = expectedTokens.isEmpty ? 0 : Double(overlap.count) / Double(expectedTokens.count)
        let wordCount = attempt.split { $0.isWhitespace || $0.isNewline }.count
        let hasDecisionLanguage = Self.containsAny(
            attempt.lowercased(),
            terms: ["because", "trade", "assumption", "therefore", "complexity", "verify", "test", "risk"]
        )

        let grade: PracticeGrade
        let feedback: String
        if overlapRatio >= 0.38, wordCount >= 35, hasDecisionLanguage {
            grade = .perfect
            feedback = "The attempt anchored on the card evidence, stated reasoning, and included a verification or tradeoff cue."
        } else if overlapRatio >= 0.25, wordCount >= 24 {
            grade = .correctHesitation
            feedback = "The attempt used relevant evidence but needs a clearer decision, reason, or verification step."
        } else if overlapRatio >= 0.16 || hasDecisionLanguage {
            grade = .correctDifficult
            feedback = "The attempt is directionally related, but it is missing enough of the source evidence to be reliable."
        } else if wordCount >= 10 {
            grade = .incorrectEasyRecall
            feedback = "The attempt was complete enough to grade, but it did not connect to the card's evidence."
        } else {
            grade = .incorrectHardRecall
            feedback = "The attempt was too short to show the reasoning this card is drilling."
        }

        return PracticeAttemptEvaluation(
            grade: grade,
            confidence: Int((min(0.98, max(0.35, overlapRatio)) * 100).rounded()),
            feedback: feedback,
            attemptTranscript: attempt
        )
    }

    private static func tokens(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "into", "there", "their", "would",
            "should", "could", "about", "because", "first", "second", "third", "here", "what",
            "when", "then", "than", "your", "were", "have", "will", "they", "them", "card"
        ]
        let raw = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(raw.filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }
}
