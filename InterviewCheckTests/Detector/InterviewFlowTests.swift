import XCTest
@testable import InterviewCheck

/// A whole interview against a fake clock, fake AI and a temporary database.
@MainActor
final class InterviewFlowTests: XCTestCase {
    private typealias F = DetectorFixtures
    private var databasePath: String!
    private var database: SessionDatabase!
    private var now: TimeInterval = 1_000
    private var timeline: InterviewTimeline!
    private var controller: InterviewController!
    private var settings: DetectorSettings!

    override func setUp() async throws {
        databasePath = NSTemporaryDirectory() + "interview-flow-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        timeline = InterviewTimeline(uptime: { [unowned self] in self.now })
        settings = DetectorSettings(defaults: UserDefaults(suiteName: "flow.\(UUID().uuidString)")!)
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        controller = InterviewController(timeline: timeline, database: database, settings: settings)
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.questionSettleDelay = 0
        controller.answerSettleDelay = 0
        controller.roleProvider = { nil }
        controller.runner = ReferenceAnswerRunner(
            makeClient: { _, _ in FakeTextClient(reply: F.aiAnswer) }, clock: { 0 }, deliver: { $0() })
    }

    override func tearDown() async throws {
        controller.stopTicking()
        database = nil
        try? FileManager.default.removeItem(atPath: databasePath)
    }

    func testDoubleKeypressIsOneQuestion() async throws {
        controller.consentConfirmed = true
        controller.start()
        let question = F.words(F.question, side: .interviewer, start: now + 1)
        timeline.append(question)
        now = question.last!.end + 0.2
        controller.markQuestion()
        now += 0.3
        controller.markQuestion()
        XCTAssertEqual(controller.questions.count, 1, "a second press before any answer re-marks the same question")
        try await waitUntil { self.controller.questions.first?.text.isEmpty == false }
        XCTAssertEqual(controller.questions.first?.text, F.question)
    }

    func testLateWordsAreSavedOnceEvenWhenSortedIntoTheMiddle() {
        controller.consentConfirmed = true
        controller.start()
        let early = F.words("I would use a token bucket", side: .candidate, start: now + 10)
        let nod = F.words("Mm-hmm.", side: .interviewer, start: now + 15)
        timeline.append(early + nod)
        controller.flushWords()
        // A slower batch from the call audio lands between them.
        let late = F.words("per key in Redis", side: .candidate, start: early.last!.end + 0.1)
        timeline.append(late)
        controller.flushWords()
        let saved = database.loadInterviewWords(interviewID: controller.interview!.id)
        XCTAssertEqual(saved.count, early.count + nod.count + late.count, "every word once, none twice")
        XCTAssertEqual(Set(saved.map(\.text)).count, Set((early + nod + late).map(\.text)).count)
    }

    func testALateKeypressDoesNotGiveTheNextAnswerToThePreviousQuestion() async throws {
        controller.consentConfirmed = true
        controller.start()
        let q1 = F.words("Tell me about a hard bug you fixed.", side: .interviewer, start: now + 1)
        timeline.append(q1)
        now = q1.last!.end + 0.3
        controller.markQuestion()
        let a1 = F.words("We had a race condition in billing that charged twice", side: .candidate, start: now + 1)
        let q2 = F.words("How did you find it in production?", side: .interviewer, start: a1.last!.end + 2)
        let a2 = F.words("I added tracing around the charge path", side: .candidate, start: q2.last!.end + 1)
        timeline.append(a1 + q2 + a2)
        now = a2.last!.end + 0.5
        controller.markQuestion()   // pressed after Q2 was asked and partly answered
        let first = controller.questions[0]
        XCTAssertEqual(first.closedAt.map { $0 + controller.origin } ?? 0, q2.first!.start, accuracy: 0.01)
        XCTAssertFalse(first.answerText.contains("tracing"), "the second answer is not the first one's")
        XCTAssertTrue(first.answerText.hasPrefix("We had a race condition"))
    }

    func testForgottenKeypressIsMarkedAutomaticallyOnce() async throws {
        settings.autoMarkQuestions = true
        controller.consentConfirmed = true
        controller.start()
        let question = F.words(F.question, side: .interviewer, start: now + 1)
        let answer = F.words("I would use a token bucket per key stored in Redis so every gateway agrees on the count",
                             side: .candidate, start: question.last!.end + 1.5)
        timeline.append(question)
        now = question.last!.end + 0.5
        controller.tick()
        XCTAssertTrue(controller.questions.isEmpty, "no answer yet: nothing is marked")
        timeline.append(answer)
        now = answer.last!.end + 0.5
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.questions.count, 1, "marked once, not every tick")
        let marked = controller.questions[0]
        XCTAssertEqual(marked.markedAt + controller.origin, question.last!.end, accuracy: 0.01, "timed at the question's end")
        XCTAssertTrue(controller.autoMarkedIDs.contains(marked.id))
        try await waitUntil { self.controller.questions.first?.text.isEmpty == false }
        XCTAssertEqual(controller.questions.first?.text, F.question)
        XCTAssertEqual(controller.liveWindow?.answerWords.count, answer.count)
    }

    func testAPressedQuestionIsNotMarkedAgain() {
        settings.autoMarkQuestions = true
        controller.consentConfirmed = true
        controller.start()
        let question = F.words(F.question, side: .interviewer, start: now + 1)
        timeline.append(question)
        now = question.last!.end + 0.3
        controller.markQuestion()
        timeline.append(F.words("I would use a token bucket per key stored in Redis so every gateway agrees",
                                side: .candidate, start: now + 1))
        now += 10
        controller.tick()
        XCTAssertEqual(controller.questions.count, 1)
        XCTAssertTrue(controller.autoMarkedIDs.isEmpty)
    }

    func testAForgottenSecondQuestionIsMarkedAfterAPressedFirst() {
        settings.autoMarkQuestions = true
        controller.consentConfirmed = true
        controller.start()
        let q1 = F.words("Tell me about a hard bug you fixed recently.", side: .interviewer, start: now + 1)
        timeline.append(q1)
        now = q1.last!.end + 0.3
        controller.markQuestion()
        let a1 = F.words("We had a race condition in billing where two workers charged the same invoice twice",
                         side: .candidate, start: now + 1)
        let q2 = F.words("How did you find it in production?", side: .interviewer, start: a1.last!.end + 2)
        let a2 = F.words("I added tracing around the charge path and saw two workers take the same message",
                         side: .candidate, start: q2.last!.end + 1)
        timeline.append(a1 + q2 + a2)
        now = a2.last!.end + 0.5
        controller.tick()
        XCTAssertEqual(controller.questions.count, 2)
        XCTAssertEqual(controller.questions[1].markedAt + controller.origin, q2.last!.end, accuracy: 0.01)
        XCTAssertFalse(controller.questions[0].answerText.contains("tracing"), "Q1's answer ends where Q2 began")
    }

    func testStartNeedsConsent() {
        controller.start()
        XCTAssertEqual(controller.phase, .setup)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testReadingAnswerIsFlaggedAndSaved() async throws {
        controller.consentConfirmed = true
        controller.candidateName = "Sam Test"
        controller.start()
        XCTAssertEqual(controller.phase, .live)

        // The interviewer asks; the key is pressed right after.
        let question = F.words(F.question, side: .interviewer, start: now + 1)
        timeline.append(question)
        now = question.last!.end + 0.3
        controller.markQuestion()
        try await waitUntil { self.controller.questions.first?.text.isEmpty == false }
        XCTAssertEqual(controller.questions.first?.text, F.question)

        // References come from the fake client only if a key is saved; inject them directly.
        let questionID = controller.questions[0].id
        controller.upsertReference(ReferenceAnswerRecord(
            id: "ref", questionID: questionID, provider: .openai, model: "gpt-5.2", promptName: "Copilot",
            text: F.aiAnswer, firstSentenceSeconds: 3.1, totalSeconds: 6))
        controller.referencesInFlight.remove(questionID)

        // The candidate reads the AI answer after a long pause.
        let answer = F.readingAnswer(after: question.last!.end)
        timeline.append(answer)
        now = answer.last!.end + 1
        controller.tick()
        XCTAssertNotNil(controller.liveWindow)

        controller.answerDone()
        try await waitUntil { self.controller.scores[questionID]?.isFinal == true }
        let score = try XCTUnwrap(controller.scores[questionID])
        XCTAssertGreaterThanOrEqual(score.percent, 75)
        XCTAssertEqual(score.metrics.substantiveLatency ?? 0, 6.4, accuracy: 0.05)

        controller.end()
        XCTAssertEqual(controller.phase, .ended)

        let report = try XCTUnwrap(database.loadInterviewReport(id: controller.interview!.id))
        XCTAssertEqual(report.interview.candidateName, "Sam Test")
        XCTAssertNotNil(report.interview.consentConfirmedAt)
        XCTAssertEqual(report.questions.count, 1)
        XCTAssertEqual(report.questions[0].text, F.question)
        XCTAssertEqual(report.scores[questionID]?.percent, score.percent)
        XCTAssertEqual(report.interview.flaggedCount, 1)
        XCTAssertEqual(database.loadInterviewWords(interviewID: report.interview.id).count,
                       question.count + answer.count)
        XCTAssertEqual(database.loadInterviews().first?.id, report.interview.id)

        database.deleteInterview(id: report.interview.id)
        XCTAssertNil(database.loadInterviewReport(id: report.interview.id))
    }

    func testRoleProfileRoundTrips() {
        var profile = RoleProfile(workspaceID: "w1", jobDescription: "Senior Go engineer")
        profile.plannedQuestions = [PlannedQuestion(text: "Why Go?", family: nil, strongAnswer: "Trade-offs")]
        database.saveRoleProfile(profile)
        let loaded = database.loadRoleProfile(workspaceID: "w1")
        XCTAssertEqual(loaded?.jobDescription, "Senior Go engineer")
        XCTAssertEqual(loaded?.plannedQuestions.first?.text, "Why Go?")
        XCTAssertEqual(loaded?.cheaterPrompts.count, 3)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
