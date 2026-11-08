import Combine
import Foundation
import InterviewCheckConnectors
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
        /// The name from a meeting transcript, when there is one.
        var name: String?
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
    private var scoredFrom = ScoredFrom.recording
    private var recordingID: String?
    private var cleanupFolder: URL?
    /// When the meeting happened, for recordings from a connector.
    var meetingStart: Date?
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
        meetingStart = nil
        step = .idle
        speakers = []
        candidateSpeaker = nil
        words = []
    }

    /// Step 1: read and transcribe the file. `recordingID` links a meeting
    /// recording from a connector; `cleanup` is a download folder to delete.
    func start(file: URL, candidateName: String, role: RoleProfile?, recordingID: String? = nil, cleanup: URL? = nil) {
        self.fileURL = file
        self.candidateName = candidateName
        self.role = role
        self.recordingID = recordingID
        self.cleanupFolder = cleanup
        scoredFrom = .recording
        task = Task { @MainActor in
            defer { self.removeCleanupFolder() }
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

    /// Step 1 for a meeting transcript (WebVTT with speaker names): no
    /// Deepgram call; words are spread evenly over each line's time.
    func startTranscript(file: URL, candidateName: String, role: RoleProfile?, recordingID: String? = nil, cleanup: URL? = nil) {
        self.candidateName = candidateName
        self.role = role
        self.recordingID = recordingID
        scoredFrom = .transcript
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            step = .failed("The transcript could not be read.")
            return
        }
        let (transcriptWords, names) = Self.words(from: WebVTT.cues(in: text))
        words = transcriptWords
        speakers = Self.speakerSamples(words).map { sample in
            var named = sample
            named.name = names[sample.id]
            return named
        }
        guard speakers.count >= 2 else {
            step = .failed("This transcript has no speaker names, so questions and answers can't be told apart. Analyze the recording instead.")
            return
        }
        let wanted = candidateName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        candidateSpeaker = speakers.first { !wanted.isEmpty && ($0.name ?? "").lowercased().contains(wanted) }?.id
            ?? speakers.max { $0.wordCount < $1.wordCount }?.id
        step = .chooseSpeaker
    }

    /// Words from transcript lines, one speaker index per distinct name.
    static func words(from cues: [TranscriptCue]) -> ([DeepgramWord], [Int: String]) {
        var indexes: [String: Int] = [:]
        var words: [DeepgramWord] = []
        for cue in cues {
            let name = cue.speaker ?? "Unknown"
            let speaker = indexes[name] ?? indexes.count
            indexes[name] = speaker
            let tokens = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let step = tokens.isEmpty ? 0 : (cue.end - cue.start) / Double(tokens.count)
            for (index, token) in tokens.enumerated() {
                let start = cue.start + Double(index) * step
                let bare = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
                words.append(DeepgramWord(word: bare.isEmpty ? token : bare, start: start, end: start + step * 0.9,
                                          confidence: nil, speaker: speaker, punctuatedWord: token))
            }
        }
        return (words, Dictionary(uniqueKeysWithValues: indexes.map { ($0.value, $0.key) }))
    }

    private func removeCleanupFolder() {
        if let cleanupFolder { try? FileManager.default.removeItem(at: cleanupFolder) }
        cleanupFolder = nil
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

        let created = meetingStart ?? (try? fileURL?.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var interview = InterviewRecord(
            id: UUID().uuidString, workspaceID: role?.id, roleTitle: role?.displayTitle ?? "",
            candidateName: candidateName.trimmingCharacters(in: .whitespaces),
            consentConfirmedAt: Date(), startedAt: created,
            endedAt: created.addingTimeInterval(timed.last?.end ?? 0), scoredFrom: scoredFrom
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
            // Transcript timing is per sentence: never more than low confidence.
            let coarse = scoredFrom == .transcript
            let quick = evaluator.evaluate(questionText: question.text, window: window, references: references,
                                           hasTimingGap: coarse, answerEmbedding: answerEmbedding,
                                           referenceEmbeddings: referenceEmbeddings)
            let judge = try? await reviewer.judge(questionText: question.text, window: window,
                                                  references: references, quick: quick)
            let score = evaluator.evaluate(questionText: question.text, window: window, references: references,
                                           hasTimingGap: coarse, answerEmbedding: answerEmbedding,
                                           referenceEmbeddings: referenceEmbeddings, judge: judge ?? nil)
            let record = AnswerScoreRecord(
                questionID: question.id, percent: score.percent, confidence: score.confidence,
                reasons: score.reasons, counterpoints: score.counterpoints, followUps: score.followUps,
                metrics: AnswerMetrics(score: score, timingGap: coarse), isFinal: true
            )
            database.saveAnswerScore(record)
            finals.append(record)
        }

        interview.questionCount = marks.count
        interview.flaggedCount = finals.filter { $0.percent >= 70 }.count
        interview.overallPercent = InterviewSummary.overall(finals)
        database.saveInterview(interview)
        if let recordingID { database.markRecordingAnalyzed(recordingID, interviewID: interview.id) }
        return (interview.id, marks.count)
    }
}
