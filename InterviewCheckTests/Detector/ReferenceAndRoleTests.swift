import XCTest
@testable import InterviewCheck

/// A client that returns fixed text, streamed in two chunks.
struct FakeTextClient: DetectorTextGenerating {
    var label = "Fake"
    var reply: String
    var fails = false

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        if fails { throw DetectorClientError.emptyReply }
        let middle = reply.index(reply.startIndex, offsetBy: reply.count / 2)
        onChunk(String(reply[..<middle]))
        onChunk(String(reply[middle...]))
        return reply
    }
}

final class ReferenceAndRoleTests: XCTestCase {
    private let claude = LineupEntry(id: "c", provider: .claude, model: "claude-sonnet-5")
    private let gpt = LineupEntry(id: "g", provider: .openai, model: "gpt-5.2")
    private let mini = LineupEntry(id: "m", provider: .openai, model: "gpt-4o-mini")

    func testPlanCoversEveryProviderAndPromptWithinTheCap() {
        let runs = ReferenceAnswerRunner.plan(lineup: [claude, gpt, mini], prompts: CheaterPromptLibrary.defaults)
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(Set(runs.map(\.entry.id)), ["c", "g", "m"])
        XCTAssertEqual(Set(runs.map(\.prompt.id)), Set(CheaterPromptLibrary.defaults.map(\.id)))
        XCTAssertEqual(Set(runs.map { "\($0.entry.id)|\($0.prompt.id)" }).count, 6, "no duplicate pairs")
    }

    func testPlanSkipsDisabledEntriesAndPrompts() {
        var off = gpt
        off.isEnabled = false
        var prompts = CheaterPromptLibrary.defaults
        prompts[1].isEnabled = false
        let runs = ReferenceAnswerRunner.plan(lineup: [claude, off], prompts: prompts)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { $0.entry.id == "c" && $0.prompt.isEnabled })
    }

    func testRunnerStreamsAndRecordsFirstSentenceTiming() async {
        let reply = "I would use a token bucket per API key stored in Redis. It refills steadily."
        var now: TimeInterval = 10
        let runner = ReferenceAnswerRunner(
            makeClient: { provider, _ in FakeTextClient(reply: provider == .claude ? reply : "", fails: provider != .claude) },
            clock: { now += 0.5; return now },
            deliver: { $0() }
        )
        var updates = 0
        let results = await runner.run(
            questionID: "q1", question: "Design a rate limiter", context: .empty,
            runs: [ReferenceRun(entry: claude, prompt: CheaterPromptLibrary.talkingPoints),
                   ReferenceRun(entry: gpt, prompt: CheaterPromptLibrary.star)],
            onUpdate: { _ in updates += 1 }
        )
        XCTAssertEqual(results.count, 2)
        let good = results.first { $0.provider == .claude }!
        XCTAssertEqual(good.text, reply)
        XCTAssertNotNil(good.firstSentenceSeconds)
        XCTAssertNil(good.error)
        XCTAssertFalse(good.isStreaming)
        XCTAssertNotNil(results.first { $0.provider == .openai }?.error)
        XCTAssertGreaterThanOrEqual(updates, 4)
    }

    func testCompleteSentenceNeedsEightWords() {
        XCTAssertFalse(StreamBuffer.hasCompleteSentence("Great question."))
        XCTAssertFalse(StreamBuffer.hasCompleteSentence("I would use a token bucket per key"))
        XCTAssertTrue(StreamBuffer.hasCompleteSentence("Great question. I would use a token bucket per key."))
    }

    func testCopilotRequestUsesTheRealCandidatePrompt() {
        let context = RoleContext(roleTitle: "Backend Engineer", jobDescription: "Go, Postgres, Kafka.",
                                  resume: "Built billing at Acme.")
        let request = CheaterPromptLibrary.request(for: CheaterPromptLibrary.copilot,
                                                   question: "Tell me about a time you disagreed with your manager.",
                                                   context: context)
        XCTAssertTrue(request.appliesVoiceGuard)
        XCTAssertTrue(request.user.contains("Tell me about a time you disagreed"))
        XCTAssertTrue(request.user.contains("Built billing at Acme."))
        XCTAssertFalse(request.system.isEmpty)
    }

    func testCustomPromptRequestCarriesContextAndQuestion() {
        let context = RoleContext(roleTitle: "PM", jobDescription: "Own the roadmap.", resume: "")
        let request = CheaterPromptLibrary.request(for: CheaterPromptLibrary.talkingPoints,
                                                   question: "Why this role?", context: context)
        XCTAssertEqual(request.system, CheaterPromptLibrary.talkingPoints.instructions)
        XCTAssertTrue(request.user.contains("JOB DESCRIPTION (PM):\nOwn the roadmap."))
        XCTAssertTrue(request.user.hasSuffix("THE INTERVIEWER JUST ASKED:\nWhy this role?\n\nRespond now."))
    }

    func testRoleDraftParsesAndApplies() {
        let reply = """
        Here you go:
        {"questions": [{"question": "How would you shard our Postgres orders table?",
                        "strong_answer": "Picks a key, discusses hot spots."},
                       {"question": "  ", "strong_answer": "dropped"}],
         "talking_points_prompt": "Assist a senior Go engineer...",
         "star_prompt": ""}
        """
        let draft = RoleDraftService.parse(reply)
        XCTAssertEqual(draft?.questions.count, 1)
        XCTAssertEqual(draft?.questions.first?.strongAnswer, "Picks a key, discusses hot spots.")
        XCTAssertEqual(draft?.promptInstructions.count, 1)

        let profile = RoleDraftService.apply(draft!, to: RoleProfile(workspaceID: "w"))
        XCTAssertEqual(profile.plannedQuestions.count, 1)
        XCTAssertEqual(profile.cheaterPrompts.first { $0.id == CheaterPromptLibrary.talkingPoints.id }?.instructions,
                       "Assist a senior Go engineer...")
        XCTAssertEqual(profile.cheaterPrompts.first { $0.id == CheaterPromptLibrary.star.id }?.instructions,
                       CheaterPromptLibrary.star.instructions)
    }

    func testRoleDraftRejectsNonsense() {
        XCTAssertNil(RoleDraftService.parse("no json here"))
        XCTAssertNil(RoleDraftService.parse("{\"questions\": []}"))
    }

    func testOverallWeighsConfidence() {
        func score(_ percent: Int, _ confidence: ScoreConfidence) -> AnswerScoreRecord {
            let base = CheatScorer.score(timing: TimingSignal.evaluate(answerWords: [], questionEnd: 0, questionText: ""),
                                         fluency: FluencySignal.evaluate(answerWords: [], from: nil),
                                         similarity: nil, judge: nil, hasTimingGap: false)
            return AnswerScoreRecord(questionID: UUID().uuidString, percent: percent, confidence: confidence,
                                     reasons: [], counterpoints: [], followUps: [],
                                     metrics: AnswerMetrics(score: base, timingGap: false), isFinal: true)
        }
        XCTAssertNil(InterviewSummary.overall([]))
        XCTAssertEqual(InterviewSummary.overall([score(90, .high), score(10, .low)]), 67)
    }
}
