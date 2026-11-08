import SwiftUI
import XCTest
@testable import memanager

/// Renders the detector screens with sample data, light and dark, to PNG.
/// Opt in with MEMANAGER_RENDER_SMOKE=1; files land in MEMANAGER_RENDER_DIR.
@MainActor
final class DetectorRenderTests: XCTestCase {
    private typealias F = DetectorFixtures
    private var now: TimeInterval = 5_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    /// A controller mid-interview: one answered question (flagged), one live.
    private func liveController() throws -> (InterviewController, InterviewTimeline) {
        let path = NSTemporaryDirectory() + "render-\(UUID().uuidString).sqlite"
        let timeline = InterviewTimeline(uptime: { [unowned self] in self.now })
        let settings = DetectorSettings(defaults: UserDefaults(suiteName: "render.\(UUID().uuidString)")!)
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        let controller = InterviewController(timeline: timeline, database: SessionDatabase(databasePath: path),
                                             settings: settings)
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.questionSettleDelay = 0
        controller.roleProvider = { (nil, nil) }
        controller.candidateName = "Jordan Rivera"
        controller.consentConfirmed = true
        controller.start()
        controller.stopTicking()

        let question = F.words(F.question, side: .interviewer, start: now + 1)
        timeline.append(question)
        now = question.last!.end + 0.3
        controller.markQuestion(planned: PlannedQuestion(text: F.question, family: "System design", strongAnswer: ""))
        let id = controller.questions[0].id
        controller.referenceGeneration[id] = 99
        controller.referencesInFlight.remove(id)
        for (index, sample) in Self.samples.enumerated() {
            controller.upsertReference(ReferenceAnswerRecord(
                id: "r\(index)", questionID: id, provider: sample.0, model: sample.1, promptName: sample.2,
                text: sample.3, firstSentenceSeconds: 2.4 + Double(index), totalSeconds: 9))
        }
        let answer = F.readingAnswer(after: question.last!.end)
        timeline.append(answer)
        now = answer.last!.end + 0.5
        controller.tick()
        let window = controller.window(for: controller.questions[0])
        var score = controller.evaluate(question: controller.questions[0], window: window)
        score = CheatScorer.score(
            timing: score.timing, fluency: score.fluency, similarity: score.similarity,
            judge: JudgeResult(likelihood: 86, confidence: "high",
                               evidence: ["Same three points in the same order as the GPT answer, including \u{201C}fail open\u{201D}"],
                               followUpQuestions: ["What bucket size and refill rate would you start with, and why?",
                                                   "Walk me through what happens when two gateways decrement the same key at once."]),
            hasTimingGap: false)
        controller.store(score, questionID: id, window: window, isFinal: true)
        return (controller, timeline)
    }

    static let samples: [(AIProviderType, String, String, String)] = [
        (.openai, "gpt-5.2", "Copilot", F.aiAnswer),
        (.claude, "claude-sonnet-5", "Talking points", """
        Say first: "I'd put a token bucket in front of every API key."
        - Keep bucket state in Redis so all gateway nodes agree
        - Refill at a steady rate; capacity allows short bursts
        - Return 429 with Retry-After when the bucket is empty
        - Tune limits per customer tier from rejection metrics
        """),
        (.openai, "gpt-4o-mini", "STAR story", """
        At my last company our public API got hammered by one partner's retry loop, which took down checkout. \
        I owned the fix. I added a Redis-backed token bucket per API key at the gateway, with a Lua script so the \
        check-and-decrement was atomic, and we returned 429s with a Retry-After header. Errors dropped 90 percent.
        """),
    ]

    func testRenderLiveInterview() async throws {
        let (controller, timeline) = try liveController()
        for width: CGFloat in [1000, 640] {
            try await OverlayRenderHarness.render("detector-live-\(Int(width))", size: CGSize(width: width, height: 1250), settle: 0.6) {
                InterviewLiveView(controller: controller, timeline: timeline, plannedQuestions: [
                    PlannedQuestion(text: F.question, family: nil, strongAnswer: "Token bucket or sliding window, shared state"),
                    PlannedQuestion(text: "Tell me about the hardest outage you owned end to end.", family: nil, strongAnswer: ""),
                    PlannedQuestion(text: "Why does this role interest you?", family: nil, strongAnswer: ""),
                ], width: width)
            }
        }
    }

    func testRenderSetup() async throws {
        let controller = InterviewController()
        controller.candidateName = "Jordan Rivera"
        try await OverlayRenderHarness.render("detector-setup", size: CGSize(width: 800, height: 900)) {
            InterviewSetupView(controller: controller, settings: DetectorSettings.shared, workspace: nil,
                               readiness: DetectorReadiness(hasDeepgramKey: false, usableLineupCount: 2),
                               onChooseRole: {}, onOpenSettings: {})
        }
    }

    func testRenderReportAndEnded() async throws {
        let (controller, _) = try liveController()
        controller.end()
        try await OverlayRenderHarness.render("detector-ended", size: CGSize(width: 800, height: 500)) {
            InterviewEndedView(controller: controller, onOpenReport: {})
        }
        let report = try XCTUnwrap(controller.database.loadInterviewReport(id: controller.interview!.id))
        try await OverlayRenderHarness.render("detector-report", size: CGSize(width: 820, height: 1100)) {
            InterviewReportView(report: report, width: 820, onDelete: {})
        }
    }

    func testRenderDetectorSettings() async throws {
        try await OverlayRenderHarness.render("detector-settings", size: CGSize(width: 720, height: 900)) {
            SettingsScreen(initialPane: .detector)
        }
    }
}
