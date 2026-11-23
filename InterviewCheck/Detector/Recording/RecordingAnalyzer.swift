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
    /// When the interviewer confirmed the candidate was told; nil when
    /// nobody confirmed it (background scoring).
    private var consentConfirmedAt: Date?
    /// When the meeting happened, for recordings from a connector.
    var meetingStart: Date?
    var database: SessionDatabase = .shared
    var settings: DetectorSettings = .shared
    var runner = ReferenceAnswerRunner()
    var transcribe: (URL) async throws -> [DeepgramWord] = { url in
        guard let key = VoiceSignatureStore.shared.loadDeepgramApiKey(), !key.isEmpty else { throw RecordingError.missingKey }
        return try await RecordingTranscriber(apiKey: key).transcribe(audioFile: url)
    }

    /// The candidate's voice was found by name (not just the busiest voice).
    @Published private(set) var candidateMatchedByName = false

    /// Reopening the sheet shows work in progress instead of cancelling it.
    func present() {
        switch step {
        case .preparing, .transcribing, .answering, .chooseSpeaker:
            isPresented = true
        default:
            reset()
            isPresented = true
        }
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
    /// `consentConfirmedAt` is stored in the report as given, never invented.
    func start(file: URL, candidateName: String, role: RoleProfile?, consentConfirmedAt: Date?,
               recordingID: String? = nil, cleanup: URL? = nil) {
        self.fileURL = file
        self.candidateName = candidateName
        self.role = role
        self.recordingID = recordingID
        self.consentConfirmedAt = consentConfirmedAt
        scoredFrom = .recording
        candidateMatchedByName = false
        task = Task { @MainActor in
            // This run's own download folder, whatever starts later.
            defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
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
                guard !Task.isCancelled else { return }
                step = speakers.isEmpty ? .failed(RecordingError.noQuestions.localizedDescription) : .chooseSpeaker
            } catch {
                // A cancelled run must not overwrite the step of the next one.
                guard !Task.isCancelled else { return }
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// Step 1 for a meeting transcript (WebVTT with speaker names): no
    /// Deepgram call; words are spread evenly over each line's time.
    func startTranscript(file: URL, candidateName: String, role: RoleProfile?, consentConfirmedAt: Date?,
                         recordingID: String? = nil, cleanup: URL? = nil) {
        self.candidateName = candidateName
        self.role = role
        self.recordingID = recordingID
        self.consentConfirmedAt = consentConfirmedAt
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
        let byName = Self.speaker(named: candidateName, in: speakers)
        candidateMatchedByName = byName != nil
        candidateSpeaker = byName ?? speakers.max { $0.wordCount < $1.wordCount }?.id
        step = .chooseSpeaker
    }

    /// The one speaker whose name holds every part of the candidate's name
    /// as a whole word ("Ian" is not "Brian"); nil when none or several do.
    static func speaker(named candidate: String, in speakers: [SpeakerSample]) -> Int? {
        let parts = Set(tokens(candidate))
        guard !parts.isEmpty else { return nil }
        let matches = speakers.filter { parts.isSubset(of: Set(tokens($0.name ?? ""))) }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func tokens(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
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

    /// Opens the report when done (Analyze Recording); background scoring
    /// turns this off so the window never switches under the interviewer.
    var showsReportWhenDone = true

    /// Step 2: with the candidate's voice chosen, analyse every answer.
    func analyze() {
        guard let candidate = candidateSpeaker else { return }
        task = Task { @MainActor in
            do {
                let id = try await runAnalysis(candidate: candidate)
                if showsReportWhenDone { AppNavigation.shared.showReport(id.interviewID) }
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
            consentConfirmedAt: consentConfirmedAt, startedAt: created,
            // No end until every answer is scored: a run cut short is then
            // finished by crash recovery instead of looking complete.
            endedAt: nil, scoredFrom: scoredFrom
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
                                           referenceEmbeddings: referenceEmbeddings, measuresFluency: !coarse)
            let judge = try? await reviewer.judge(questionText: question.text, window: window,
                                                  references: references, quick: quick)
            let score = evaluator.evaluate(questionText: question.text, window: window, references: references,
                                           hasTimingGap: coarse, answerEmbedding: answerEmbedding,
                                           referenceEmbeddings: referenceEmbeddings, judge: judge ?? nil,
                                           measuresFluency: !coarse)
            let record = AnswerScoreRecord(
                questionID: question.id, percent: score.percent, confidence: score.confidence,
                reasons: score.reasons, counterpoints: score.counterpoints, followUps: score.followUps,
                metrics: AnswerMetrics(score: score, timingGap: coarse), isFinal: true
            )
            database.saveAnswerScore(record)
            finals.append(record)
        }

        interview.endedAt = created.addingTimeInterval(timed.last?.end ?? 0)
        interview.questionCount = marks.count
        interview.flaggedCount = finals.filter { $0.percent >= 70 }.count
        interview.overallPercent = InterviewSummary.overall(finals)
        database.saveInterview(interview)
        if let recordingID { database.markRecordingAnalyzed(recordingID, interviewID: interview.id) }
        return (interview.id, marks.count)
    }
}
