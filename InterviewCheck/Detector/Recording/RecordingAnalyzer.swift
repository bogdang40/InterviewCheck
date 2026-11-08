import Combine
import Foundation
import InterviewCheckKit

/// Analyses a recorded interview (audio or video file) into a normal report:
/// transcribe with word timings, let the interviewer pick the candidate's
/// voice, find the questions, generate the AI answers, and score each answer.
@MainActor
final class RecordingAnalyzer: ObservableObject {
    static let shared = RecordingAnalyzer()

    enum Step: Equatable {
        case idle
        case preparing
        case transcribing
        case chooseSpeaker
        case answering(question: Int, of: Int)
        case finished(interviewID: String, questions: Int)
        case failed(String)
    }

    struct SpeakerSample: Identifiable, Equatable {
        let id: Int
        let wordCount: Int
        let sample: String
    }

    @Published var isPresented = false
    @Published private(set) var step: Step = .idle
    @Published private(set) var speakers: [SpeakerSample] = []
    @Published var candidateSpeaker: Int?

    private var words: [DeepgramWord] = []
    private var fileURL: URL?
    private var candidateName = ""
    private var role: RoleProfile?
    private var task: Task<Void, Never>?
    var database: SessionDatabase = .shared
    var settings: DetectorSettings = .shared
    var runner = ReferenceAnswerRunner()
    var transcribe: (URL) async throws -> [DeepgramWord] = { url in
        guard let key = VoiceSignatureStore.shared.loadDeepgramApiKey(), !key.isEmpty else { throw RecordingError.missingKey }
        return try await RecordingTranscriber(apiKey: key).transcribe(audioFile: url)
    }

    func present() {
        if case .answering = step { isPresented = true; return }
        reset()
        isPresented = true
    }

    func reset() {
        task?.cancel()
        step = .idle
        speakers = []
        candidateSpeaker = nil
        words = []
    }

    /// Step 1: read and transcribe the file.
    func start(file: URL, candidateName: String, role: RoleProfile?) {
        self.fileURL = file
        self.candidateName = candidateName
        self.role = role
        task = Task { @MainActor in
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                step = .preparing
                let audio = try await RecordingAudio.prepare(file)
                defer { if audio.isTemporary { try? FileManager.default.removeItem(at: audio.file) } }
                step = .transcribing
                words = try await transcribe(audio.file)
                speakers = Self.speakerSamples(words)
                candidateSpeaker = speakers.max { $0.wordCount < $1.wordCount }?.id
                step = speakers.isEmpty ? .failed(RecordingError.noQuestions.localizedDescription) : .chooseSpeaker
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// Step 2: with the candidate's voice chosen, analyse every answer.
    func analyze() {
        guard let candidate = candidateSpeaker else { return }
        task = Task { @MainActor in
            do {
                let id = try await runAnalysis(candidate: candidate)
                AppNavigation.shared.showReport(id.interviewID)
                step = .finished(interviewID: id.interviewID, questions: id.questions)
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    static func speakerSamples(_ words: [DeepgramWord]) -> [SpeakerSample] {
        let grouped = Dictionary(grouping: words, by: { $0.speaker ?? 0 })
        return grouped.keys.sorted().map { speaker in
            let spoken = grouped[speaker] ?? []
            let sample = spoken.prefix(40).map { $0.punctuatedWord ?? $0.word }.joined(separator: " ")
            return SpeakerSample(id: speaker, wordCount: spoken.count, sample: sample)
        }
    }

    static func timedWords(_ words: [DeepgramWord], candidate: Int) -> [TimedWord] {
        words.map { word in
            let speaker = word.speaker ?? 0
            let side: InterviewSide = speaker == candidate ? .candidate : .interviewer
            return TimedWord(side: side, speakerIndex: side == .candidate ? speaker : nil,
                             text: word.punctuatedWord ?? word.word, start: word.start, end: max(word.end, word.start),
                             confidence: word.confidence, isFiller: FillerLexicon.isFiller(word.word))
        }
    }

    private func runAnalysis(candidate: Int) async throws -> (interviewID: String, questions: Int) {
        let timed = Self.timedWords(words, candidate: candidate)
        let marks = RecordingQuestionFinder.questionMarks(in: timed)
        guard !marks.isEmpty else { throw RecordingError.noQuestions }

        let created = (try? fileURL?.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var interview = InterviewRecord(
            id: UUID().uuidString, workspaceID: role?.id, roleTitle: role?.displayTitle ?? "",
            candidateName: candidateName.trimmingCharacters(in: .whitespaces),
            consentConfirmedAt: Date(), startedAt: created,
            endedAt: created.addingTimeInterval(timed.last?.end ?? 0)
        )
        database.saveInterview(interview)
        database.appendInterviewWords(timed, interviewID: interview.id, origin: 0)

        let context = RoleContext(roleTitle: role?.displayTitle ?? "", jobDescription: role?.jobDescription ?? "", resume: "")
        let runs = ReferenceAnswerRunner.plan(lineup: settings.usableLineup(),
                                              prompts: role?.enabledPrompts ?? CheaterPromptLibrary.defaults)
        let evaluator = AnswerEvaluator(weights: settings.weights)
        let reviewer = AnswerReviewer(settings: settings)
        var finals: [AnswerScoreRecord] = []

        for (index, mark) in marks.enumerated() {
            try Task.checkCancellation()
            step = .answering(question: index + 1, of: marks.count)
            let window = QuestionTracker.resolve(
                words: timed, markedAt: mark, lowerBound: index > 0 ? marks[index - 1] : nil,
                closedAt: index + 1 < marks.count ? marks[index + 1] : nil
            )
            let question = InterviewQuestionRecord(
                id: UUID().uuidString, interviewID: interview.id, ordinal: index + 1, text: window.questionText,
                source: .live, markedAt: mark, questionEnd: window.questionEnd, answerStart: window.answerStart,
                answerEnd: window.answerEnd, closedAt: window.answerEnd,
                answerText: window.answerWords.map(\.text).joined(separator: " ")
            )
            database.saveInterviewQuestion(question)

            let references = runs.isEmpty ? [] : await runner.run(
                questionID: question.id, question: question.text, context: context, runs: runs, onUpdate: { _ in })
            references.forEach(database.saveReferenceAnswer)

            let (answerEmbedding, referenceEmbeddings) = await reviewer.embeddings(window: window, references: references)
            let quick = evaluator.evaluate(questionText: question.text, window: window, references: references,
                                           hasTimingGap: false, answerEmbedding: answerEmbedding,
                                           referenceEmbeddings: referenceEmbeddings)
            let judge = try? await reviewer.judge(questionText: question.text, window: window,
                                                  references: references, quick: quick)
            let score = evaluator.evaluate(questionText: question.text, window: window, references: references,
                                           hasTimingGap: false, answerEmbedding: answerEmbedding,
                                           referenceEmbeddings: referenceEmbeddings, judge: judge ?? nil)
            let record = AnswerScoreRecord(
                questionID: question.id, percent: score.percent, confidence: score.confidence,
                reasons: score.reasons, counterpoints: score.counterpoints, followUps: score.followUps,
                metrics: AnswerMetrics(score: score, timingGap: false), isFinal: true
            )
            database.saveAnswerScore(record)
            finals.append(record)
        }

        interview.questionCount = marks.count
        interview.flaggedCount = finals.filter { $0.percent >= 70 }.count
        interview.overallPercent = InterviewSummary.overall(finals)
        database.saveInterview(interview)
        return (interview.id, marks.count)
    }
}
