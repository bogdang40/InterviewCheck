import Foundation
import InterviewCheckKit

/// Scores one answer from its question window and the AI answers. Shared by
/// live interviews and analysed recordings.
struct AnswerEvaluator {
    var weights: CheatScoreWeights

    func evaluate(
        questionText: String,
        window: QuestionWindow,
        references: [ReferenceAnswerRecord],
        hasTimingGap: Bool,
        answerEmbedding: [Double]? = nil,
        referenceEmbeddings: [String: [Double]] = [:],
        judge: JudgeResult? = nil
    ) -> AnswerScore {
        let finished = references.filter { !$0.isStreaming && $0.error == nil && !$0.text.isEmpty }
        var timing = TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                           questionText: questionText)
        timing = TimingSignal.pacedToAI(timing, fastestFirstSentence: finished.compactMap(\.firstSentenceSeconds).min())
        let fluency = FluencySignal.evaluate(answerWords: window.answerWords, from: timing.substantiveIndex)
        let texts = finished.map {
            ReferenceText(id: UUID(), label: $0.label, text: $0.text, embedding: referenceEmbeddings[$0.id])
        }
        let similarity = texts.isEmpty ? nil : SimilaritySignal.evaluate(
            answerText: window.answerWords.map(\.text).joined(separator: " "),
            answerEmbedding: answerEmbedding, questionText: questionText, references: texts
        )
        return CheatScorer.score(timing: timing, fluency: fluency, similarity: similarity, judge: judge,
                                 hasTimingGap: hasTimingGap, weights: weights)
    }
}

/// The network parts of a final score: meaning embeddings and the AI review.
@MainActor
struct AnswerReviewer {
    let settings: DetectorSettings
    var providerSettings: SettingsManager = .shared

    /// Embeddings for the answer and each AI answer, keyed by reference id.
    func embeddings(window: QuestionWindow, references: [ReferenceAnswerRecord]) async -> ([Double]?, [String: [Double]]) {
        let key = providerSettings.apiKey(for: .openai)
        let finished = references.filter { $0.error == nil && !$0.text.isEmpty }
        guard settings.useEmbeddings, !key.isEmpty, !finished.isEmpty, window.answerWords.count >= 8 else {
            return (nil, [:])
        }
        let answer = window.answerWords.map(\.text).joined(separator: " ")
        guard let vectors = try? await OpenAIEmbeddingClient(apiKey: key).embed([answer] + finished.map(\.text)),
              vectors.count == finished.count + 1 else { return (nil, [:]) }
        var byID: [String: [Double]] = [:]
        for (reference, vector) in zip(finished, vectors.dropFirst()) { byID[reference.id] = vector }
        return (vectors.first, byID)
    }

    /// The AI review; nil when it is turned off or there is too little to review.
    func judge(questionText: String, window: QuestionWindow, references: [ReferenceAnswerRecord],
               quick: AnswerScore) async throws -> JudgeResult? {
        guard let entry = settings.usableJudge(settings: providerSettings), window.answerWords.count >= 8 else { return nil }
        let finished = references.filter { $0.error == nil && !$0.text.isEmpty }
        let prompt = JudgeSignal.userPrompt(
            question: questionText,
            annotatedAnswer: JudgeSignal.annotate(answerWords: window.answerWords, questionEnd: window.questionEnd),
            references: finished.prefix(4).map { ReferenceText(id: UUID(), label: $0.label, text: $0.text, embedding: nil) },
            timing: quick.timing, fluency: quick.fluency, similarity: quick.similarity
        )
        let client = try DetectorTextClientFactory.make(provider: entry.provider, model: entry.model,
                                                        settings: providerSettings)
        return JudgeSignal.parse(try await client.completeText(system: JudgeSignal.systemPrompt, user: prompt))
    }
}
