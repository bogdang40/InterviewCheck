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
        if phase == .live, settings.autoMarkQuestions { autoMarkIfMissed() }
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
        AnswerEvaluator(weights: settings.weights).evaluate(
            questionText: question.text, window: window, references: references[question.id] ?? [],
            hasTimingGap: hasGap(window), answerEmbedding: answerEmbedding,
            referenceEmbeddings: referenceEmbeddings, judge: judge
        )
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
        let token = UUID()
        scoringTokens[questionID] = token
        pendingScoring.insert(questionID)
        scoringTasks[questionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.scoringTokens[questionID] == token { self.pendingScoring.remove(questionID) }
            }
            await self.waitForReferences(questionID, timeout: 45)
            // Let the candidate's last words arrive before the answer is read.
            if self.answerSettleDelay > 0 { try? await Task.sleep(nanoseconds: self.answerSettleDelay) }
            guard !Task.isCancelled, let index = self.questions.firstIndex(where: { $0.id == questionID }) else { return }
            let generation = self.referenceGeneration[questionID]
            let window = self.window(for: self.questions[index])
            self.apply(window, to: index)
            self.database.saveInterviewQuestion(self.questions[index])
            self.flushWords()
            let question = self.questions[index]
            guard !window.answerWords.isEmpty else {
                self.scores[questionID] = nil
                self.refreshSummary()
                return
            }

            let reviewer = AnswerReviewer(settings: self.settings)
            let answers = self.references[questionID] ?? []
            let (answerEmbedding, referenceEmbeddings) = await reviewer.embeddings(window: window, references: answers)
            let quick = self.evaluate(question: question, window: window, answerEmbedding: answerEmbedding,
                                      referenceEmbeddings: referenceEmbeddings)
            self.store(quick, questionID: questionID, window: window, isFinal: false)

            var judge: JudgeResult?
            do {
                judge = try await reviewer.judge(questionText: question.text, window: window, references: answers,
                                                 quick: quick)
            } catch {
                self.errorMessage = "The AI review failed (\(error.localizedDescription)); the score uses the other signals."
            }
            // The question was edited and its AI answers regenerated meanwhile:
            // that generation scores again; this result is stale.
            guard !Task.isCancelled, self.referenceGeneration[questionID] == generation else { return }
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
        let runs = ReferenceAnswerRunner.plan(lineup: lineup, prompts: prompts, limit: maxReferenceRuns)
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
            // New AI answers for an answer that already closed: score again
            // (this also replaces a scoring run still using the old ones).
            if self.questions.first(where: { $0.id == questionID })?.closedAt != nil,
               generation > 1 || self.scoringTasks[questionID] == nil {
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
    /// What "overall" means, wherever it is shown.
    static let overallHelp = "The average of the answer scores, weighted by confidence, so a strong signal counts more than a weak one. Look at the flagged answers first."

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
