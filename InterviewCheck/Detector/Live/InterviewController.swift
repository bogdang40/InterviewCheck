import Combine
import Foundation
import InterviewCheckKit

/// Runs one live interview: setup, questions, AI answers, scores, saving.
@MainActor
final class InterviewController: ObservableObject {
    static let shared = InterviewController()

    enum Phase: Equatable { case setup, live, ended }

    // Setup
    @Published var candidateName = ""
    @Published var consentConfirmed = false
    @Published var resumeText = ""
    @Published var resumeFileName: String?
    /// The connector record this interview was prepared from ("greenhouse:123").
    @Published var externalRef: String?
    /// The upcoming interview Prepare started from (before any ATS match).
    @Published var preparedFrom: String?

    // Live state
    @Published private(set) var phase: Phase = .setup
    @Published private(set) var interview: InterviewRecord?
    @Published private(set) var questions: [InterviewQuestionRecord] = []
    @Published var references: [String: [ReferenceAnswerRecord]] = [:]
    @Published var scores: [String: AnswerScoreRecord] = [:]
    @Published private(set) var activeQuestionID: String?
    @Published var liveWindow: QuestionWindow?
    @Published var errorMessage: String?

    let timeline: InterviewTimeline
    let database: SessionDatabase
    let settings: DetectorSettings
    var runner = ReferenceAnswerRunner()
    /// Starts and stops both audio streams (the interviewer's microphone and
    /// the call's audio). The interview drives capture directly.
    var startAudio: () -> Void = { AudioCaptureService.shared.requestStart(reason: .newSession) }
    var stopAudio: () -> Void = { AudioCaptureService.shared.requestStop(clearTranscript: true) }
    /// The role the interview is for (the one selected in Roles).
    var roleProvider: () -> RoleProfile? = { RoleStore.shared.selectedRole }

    /// Host time the interview started; stored times are relative to it.
    private(set) var origin: TimeInterval = 0
    var savedWordCount = 0
    /// Words already written, by side, start and text: late batches are
    /// sorted into the middle of the timeline, so a count is not enough.
    var savedWordKeys: Set<String> = []
    /// Wait after a keypress so the interviewer's last words are final.
    var questionSettleDelay: UInt64 = 900_000_000
    /// The candidate's last words are still being finalized when the answer
    /// closes; the final score waits this long for them.
    var answerSettleDelay: UInt64 = 1_500_000_000
    /// Questions whose final score is still being worked out. New Interview
    /// waits for these so no score is lost.
    @Published var pendingScoring: Set<String> = []
    var scoringTokens: [String: UUID] = [:]
    /// Questions the app marked by itself (shown with an "Auto" tag).
    @Published var autoMarkedIDs: Set<String> = []
    /// At most this many AI answers per question.
    var maxReferenceRuns = ReferenceAnswerRunner.maxRuns
    var tickTimer: Timer?
    var lastLiveScore: TimeInterval = 0
    var scoringTasks: [String: Task<Void, Never>] = [:]
    var referenceTasks: [String: Task<Void, Never>] = [:]
    @Published var referencesInFlight: Set<String> = []
    var referenceGeneration: [String: Int] = [:]

    init(timeline: InterviewTimeline = .shared, database: SessionDatabase = .shared,
         settings: DetectorSettings = .shared) {
        self.timeline = timeline
        self.database = database
        self.settings = settings
    }

    var activeQuestion: InterviewQuestionRecord? { questions.first { $0.id == activeQuestionID } }
    var canStart: Bool { consentConfirmed && phase != .live }

    var roleContext: RoleContext {
        let role = roleProvider()
        return RoleContext(roleTitle: role?.displayTitle ?? "",
                           jobDescription: role?.jobDescription ?? "", resume: resumeText)
    }

    // MARK: - Start and end

    func start() {
        guard canStart else {
            errorMessage = "Confirm the candidate was told the interview is transcribed and checked."
            return
        }
        let role = roleProvider()
        let record = InterviewRecord(
            id: UUID().uuidString, workspaceID: role?.id,
            roleTitle: role?.displayTitle ?? "", candidateName: candidateName.trimmingCharacters(in: .whitespaces),
            consentConfirmedAt: Date(), startedAt: Date(), externalRef: externalRef
        )
        timeline.reset()
        origin = timeline.now
        savedWordCount = 0
        savedWordKeys = []
        questions = []
        autoMarkedIDs = []
        references = [:]
        scores = [:]
        activeQuestionID = nil
        liveWindow = nil
        errorMessage = nil
        interview = record
        phase = .live
        database.saveInterview(record)
        startAudio()
        startTicking()
    }

    func end() {
        guard phase == .live, var record = interview else { return }
        closeActiveQuestion(at: timeline.now)
        stopTicking()
        stopAudio()
        flushWords()
        record.endedAt = Date()
        interview = record
        phase = .ended
        refreshSummary()
    }

    /// Back to setup for the next candidate.
    func reset() {
        guard phase != .live, pendingScoring.isEmpty else { return }
        phase = .setup
        errorMessage = nil
        interview = nil
        questions = []
        autoMarkedIDs = []
        references = [:]
        scores = [:]
        candidateName = ""
        consentConfirmed = false
        resumeText = ""
        resumeFileName = nil
        externalRef = nil
        preparedFrom = nil
    }

    // MARK: - Questions

    /// The interviewer pressed "Question asked", or picked a planned question.
    func markQuestion(planned: PlannedQuestion? = nil) {
        markQuestion(planned: planned, at: nil, automatically: false)
    }

    /// `at` marks a time in the past (an automatic mark at the question's end).
    func markQuestion(planned: PlannedQuestion? = nil, at time: TimeInterval?, automatically: Bool) {
        guard phase == .live, let interview else { return }
        let now = time ?? timeline.now
        // Pressed twice in a row with no answer yet: the same question, marked again.
        if planned == nil, let active = activeQuestion, let index = questions.firstIndex(where: { $0.id == active.id }),
           now - (origin + active.markedAt) < 2, window(for: active).answerWords.isEmpty {
            questions[index].markedAt = now - origin
            database.saveInterviewQuestion(questions[index])
            return
        }
        let previousMark = activeQuestion.map { origin + $0.markedAt }
        // Pressed late, after the new question was asked (and maybe answered
        // a little): the previous answer ends where the new question began.
        var closeAt = now
        if let previousMark {
            let probe = QuestionTracker.resolve(words: timeline.words, markedAt: now, lowerBound: previousMark,
                                                closedAt: nil, isCandidate: timeline.isCandidate)
            if let start = probe.questionStart, start > previousMark { closeAt = min(now, start) }
        }
        closeActiveQuestion(at: closeAt)

        let question = InterviewQuestionRecord(
            id: UUID().uuidString, interviewID: interview.id, ordinal: questions.count + 1,
            text: planned?.text ?? "", source: planned == nil ? .live : .planned, markedAt: now - origin
        )
        questions.append(question)
        activeQuestionID = question.id
        database.saveInterviewQuestion(question)

        if automatically { autoMarkedIDs.insert(question.id) }
        // The interviewer's last words are often still being finalized when
        // the key is pressed; wait a moment before reading the question.
        Task { @MainActor [weak self] in
            if planned == nil, !automatically { try? await Task.sleep(nanoseconds: self?.questionSettleDelay ?? 0) }
            guard let self else { return }
            self.resolveQuestionText(id: question.id, lowerBound: previousMark)
            self.generateReferences(for: question.id)
        }
    }

    /// The candidate finished; score now rather than waiting for the next question.
    func answerDone() {
        guard phase == .live else { return }
        closeActiveQuestion(at: timeline.now)
    }

    func updateQuestionText(id: String, text: String, regenerate: Bool) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].text = text
        database.saveInterviewQuestion(questions[index])
        if regenerate { generateReferences(for: id) }
    }

    private func resolveQuestionText(id: String, lowerBound: TimeInterval?) {
        guard let index = questions.firstIndex(where: { $0.id == id }), questions[index].text.isEmpty else { return }
        let window = window(for: questions[index], lowerBound: lowerBound)
        var text = window.questionText
        let partial = AudioCaptureService.shared.partialMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty, !text.hasSuffix(partial) { text += (text.isEmpty ? "" : " ") + partial }
        questions[index].text = text
        database.saveInterviewQuestion(questions[index])
    }

    func window(for question: InterviewQuestionRecord, lowerBound: TimeInterval? = nil) -> QuestionWindow {
        let index = questions.firstIndex { $0.id == question.id }
        let previous = index.flatMap { $0 > 0 ? questions[$0 - 1] : nil }
        let floor = lowerBound ?? previous.map { origin + $0.markedAt } ?? origin
        return QuestionTracker.resolve(
            words: timeline.words, markedAt: origin + question.markedAt, lowerBound: floor,
            closedAt: question.closedAt.map { origin + $0 }, isCandidate: timeline.isCandidate
        )
    }

    func closeActiveQuestion(at time: TimeInterval) {
        guard let id = activeQuestionID, let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].closedAt = time - origin
        let window = window(for: questions[index])
        apply(window, to: index)
        activeQuestionID = nil
        liveWindow = nil
        database.saveInterviewQuestion(questions[index])
        flushWords()
        scoreFinal(questionID: id)
    }

    func apply(_ window: QuestionWindow, to index: Int) {
        questions[index].questionEnd = window.questionEnd - origin
        questions[index].answerStart = window.answerStart.map { $0 - origin }
        questions[index].answerEnd = window.answerEnd.map { $0 - origin }
        questions[index].answerText = window.answerWords.map(\.text).joined(separator: " ")
    }

    // MARK: - Words

    func flushWords() {
        guard let interview else { return }
        let words = timeline.words
        guard words.count > savedWordCount || words.count != savedWordKeys.count else { return }
        let unsaved = words.filter { !savedWordKeys.contains(Self.key($0)) }
        guard !unsaved.isEmpty else { return }
        database.appendInterviewWords(unsaved, interviewID: interview.id, origin: origin)
        unsaved.forEach { savedWordKeys.insert(Self.key($0)) }
        savedWordCount = words.count
    }

    static func key(_ word: TimedWord) -> String {
        "\(word.side.rawValue)|\(Int((word.start * 1000).rounded()))|\(word.text)"
    }

    /// Keeps the list's overall line current.
    func refreshSummary() {
        guard var record = interview else { return }
        let finals = questions.compactMap { scores[$0.id] }.filter(\.isFinal)
        record.questionCount = questions.count
        record.flaggedCount = finals.filter { $0.percent >= 70 }.count
        record.overallPercent = InterviewSummary.overall(finals)
        interview = record
        database.saveInterview(record)
    }
}
