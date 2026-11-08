import Foundation
import InterviewCheckKit

extension InterviewController {
    // MARK: - Live updates

    func startTicking() {
        stopTicking()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Once a second: refresh the active answer; every few seconds, a quick
    /// local score (no model calls) so the interviewer sees it build.
    func tick() {
        guard phase == .live, let question = activeQuestion,
              let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
        let window = window(for: question)
        liveWindow = window
        apply(window, to: index)
        let now = timeline.now
        if window.answerWords.count >= 20, now - lastLiveScore >= 3 {
            lastLiveScore = now
            store(evaluate(question: questions[index], window: window), questionID: question.id,
                  window: window, isFinal: false)
        }
        if timeline.words.count - savedWordCount > 200 { flushWords() }
    }

    // MARK: - Scoring

    func evaluate(
        question: InterviewQuestionRecord,
        window: QuestionWindow,
        answerEmbedding: [Double]? = nil,
        referenceEmbeddings: [String: [Double]] = [:],
        judge: JudgeResult? = nil
    ) -> AnswerScore {
        let finished = (references[question.id] ?? []).filter { !$0.isStreaming && $0.error == nil && !$0.text.isEmpty }
        var timing = TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                           questionText: question.text)
        timing = TimingSignal.pacedToAI(timing, fastestFirstSentence: finished.compactMap(\.firstSentenceSeconds).min())
        let fluency = FluencySignal.evaluate(answerWords: window.answerWords, from: timing.substantiveIndex)
        let texts = finished.map {
            ReferenceText(id: UUID(), label: $0.label, text: $0.text, embedding: referenceEmbeddings[$0.id])
        }
        let similarity = texts.isEmpty ? nil : SimilaritySignal.evaluate(
            answerText: window.answerWords.map(\.text).joined(separator: " "),
            answerEmbedding: answerEmbedding, questionText: question.text, references: texts
        )
        return CheatScorer.score(timing: timing, fluency: fluency, similarity: similarity, judge: judge,
                                 hasTimingGap: hasGap(window), weights: settings.weights)
    }

    func hasGap(_ window: QuestionWindow) -> Bool {
        timeline.hasGap(between: window.questionEnd, and: window.answerEnd ?? timeline.now)
    }

    func store(_ score: AnswerScore, questionID: String, window: QuestionWindow, isFinal: Bool) {
        // A live estimate never replaces a final score.
        if !isFinal, scores[questionID]?.isFinal == true { return }
        let record = AnswerScoreRecord(
            questionID: questionID, percent: score.percent, confidence: score.confidence,
            reasons: score.reasons, counterpoints: score.counterpoints, followUps: score.followUps,
            metrics: AnswerMetrics(score: score, timingGap: hasGap(window)), isFinal: isFinal
        )
        scores[questionID] = record
        if isFinal { database.saveAnswerScore(record) }
    }

    /// After the answer closes: wait for the AI answers, add meaning
    /// similarity and the judge's review, then save the final score.
    func scoreFinal(questionID: String) {
        scoringTasks[questionID]?.cancel()
        scoringTasks[questionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForReferences(questionID, timeout: 45)
            guard !Task.isCancelled, let question = self.questions.first(where: { $0.id == questionID }) else { return }
            let window = self.window(for: question)
            guard !window.answerWords.isEmpty else {
                self.scores[questionID] = nil
                self.refreshSummary()
                return
            }

            let (answerEmbedding, referenceEmbeddings) = await self.embeddings(for: questionID, window: window)
            let quick = self.evaluate(question: question, window: window, answerEmbedding: answerEmbedding,
                                      referenceEmbeddings: referenceEmbeddings)
            self.store(quick, questionID: questionID, window: window, isFinal: false)

            let judge = await self.runJudge(question: question, window: window, quick: quick)
            guard !Task.isCancelled else { return }
            let final = self.evaluate(question: question, window: window, answerEmbedding: answerEmbedding,
                                      referenceEmbeddings: referenceEmbeddings, judge: judge)
            self.store(final, questionID: questionID, window: window, isFinal: true)
            self.refreshSummary()
        }
    }

    func waitForReferences(_ questionID: String, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while referencesInFlight.contains(questionID), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func embeddings(for questionID: String, window: QuestionWindow) async -> ([Double]?, [String: [Double]]) {
        let key = SettingsManager.shared.apiKey(for: .openai)
        let finished = (references[questionID] ?? []).filter { $0.error == nil && !$0.text.isEmpty }
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

    private func runJudge(question: InterviewQuestionRecord, window: QuestionWindow, quick: AnswerScore) async -> JudgeResult? {
        guard let entry = settings.usableJudge(), window.answerWords.count >= 8 else { return nil }
        let finished = (references[question.id] ?? []).filter { $0.error == nil && !$0.text.isEmpty }
        let prompt = JudgeSignal.userPrompt(
            question: question.text,
            annotatedAnswer: JudgeSignal.annotate(answerWords: window.answerWords, questionEnd: window.questionEnd),
            references: finished.prefix(4).map { ReferenceText(id: UUID(), label: $0.label, text: $0.text, embedding: nil) },
            timing: quick.timing, fluency: quick.fluency, similarity: quick.similarity
        )
        do {
            let client = try DetectorTextClientFactory.make(provider: entry.provider, model: entry.model)
            return JudgeSignal.parse(try await client.completeText(system: JudgeSignal.systemPrompt, user: prompt))
        } catch {
            errorMessage = "The AI review failed (\(error.localizedDescription)); the score uses the other signals."
            return nil
        }
    }

    // MARK: - AI answers

    func generateReferences(for questionID: String) {
        guard let question = questions.first(where: { $0.id == questionID }) else { return }
        let text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "No question was heard. Type it in to generate the AI answers."
            return
        }
        let lineup = settings.usableLineup()
        guard !lineup.isEmpty else {
            errorMessage = "Add a Claude or OpenAI key in Settings to generate AI answers."
            return
        }
        let prompts = roleProvider()?.enabledPrompts ?? CheaterPromptLibrary.defaults
        let runs = ReferenceAnswerRunner.plan(lineup: lineup, prompts: prompts)
        let generation = (referenceGeneration[questionID] ?? 0) + 1
        referenceGeneration[questionID] = generation
        references[questionID] = []
        referencesInFlight.insert(questionID)
        let context = roleContext

        referenceTasks[questionID]?.cancel()
        referenceTasks[questionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.runner.run(questionID: questionID, question: text, context: context,
                                                runs: runs) { [weak self] record in
                guard let self, self.referenceGeneration[questionID] == generation else { return }
                MainActor.assumeIsolated { self.upsertReference(record) }
            }
            guard self.referenceGeneration[questionID] == generation else { return }
            results.forEach(self.database.saveReferenceAnswer)
            self.referencesInFlight.remove(questionID)
            // An edited question on an answer that already closed: score again.
            if self.questions.first(where: { $0.id == questionID })?.closedAt != nil,
               self.scoringTasks[questionID] == nil || self.scores[questionID]?.isFinal == true {
                self.scoreFinal(questionID: questionID)
            }
        }
    }

    func upsertReference(_ record: ReferenceAnswerRecord) {
        var list = references[record.questionID] ?? []
        if let index = list.firstIndex(where: { $0.id == record.id }) {
            list[index] = record
        } else {
            list.append(record)
        }
        references[record.questionID] = list
    }
}

/// The interview's overall line.
enum InterviewSummary {
    /// Average of final scores weighted by confidence; nil with no scores.
    static func overall(_ scores: [AnswerScoreRecord]) -> Int? {
        let weighted = scores.map { score -> (Double, Double) in
            let weight: Double
            switch score.confidence {
            case .high: weight = 1
            case .medium: weight = 0.7
            case .low: weight = 0.4
            }
            return (Double(score.percent) * weight, weight)
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return Int((weighted.reduce(0) { $0 + $1.0 } / total).rounded())
    }
}
