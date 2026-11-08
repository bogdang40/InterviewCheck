import XCTest
@testable import memanager

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
        controller.roleProvider = { nil }
        controller.runner = ReferenceAnswerRunner(
            makeClient: { _, _ in FakeTextClient(reply: F.aiAnswer) }, clock: { 0 }, deliver: { $0() })
    }

    override func tearDown() async throws {
        controller.stopTicking()
        database = nil
        try? FileManager.default.removeItem(atPath: databasePath)
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
