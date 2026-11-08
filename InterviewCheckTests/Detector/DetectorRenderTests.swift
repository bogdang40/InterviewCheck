import SwiftUI
import XCTest
@testable import InterviewCheck
import InterviewCheckKit

/// Renders the native screens with sample data, light and dark, to PNG.
/// Opt in with INTERVIEWCHECK_RENDER_SMOKE=1; files land in INTERVIEWCHECK_RENDER_DIR.
@MainActor
final class DetectorRenderTests: XCTestCase {
    private typealias F = DetectorFixtures
    private var now: TimeInterval = 5_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        try RenderHarness.skipUnlessEnabled()
    }

    /// A controller mid-interview with one answered, flagged question.
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
        controller.roleProvider = { nil }
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
            let record = ReferenceAnswerRecord(
                id: "r\(index)", questionID: id, provider: sample.0, model: sample.1, promptName: sample.2,
                text: sample.3, firstSentenceSeconds: 2.4 + Double(index), totalSeconds: 9)
            controller.upsertReference(record)
            controller.database.saveReferenceAnswer(record)
        }
        let answer = F.readingAnswer(after: question.last!.end)
        timeline.append(answer)
        now = answer.last!.end + 0.5
        controller.tick()
        let window = controller.window(for: controller.questions[0])
        let base = controller.evaluate(question: controller.questions[0], window: window)
        let score = CheatScorer.score(
            timing: base.timing, fluency: base.fluency, similarity: base.similarity,
            judge: JudgeResult(likelihood: 86, confidence: "high",
                               evidence: ["Same three points in the same order as the GPT answer, including \u{201C}fail open\u{201D}"],
                               followUpQuestions: ["What bucket size and refill rate would you start with, and why?",
                                                   "Walk me through what happens when two gateways decrement the same key at once."]),
            hasTimingGap: false)
        controller.store(score, questionID: id, window: window, isFinal: true)
        controller.errorMessage = nil
        return (controller, timeline)
    }

    static let samples: [(AIProviderType, String, String, String)] = [
        (.openai, "gpt-5.2", "Copilot", F.aiAnswer),
        (.claude, "claude-sonnet-5", "Talking points", """
        Say first: "I'd put a token bucket in front of every API key."
        - Keep bucket state in Redis so all gateway nodes agree
        - Refill at a steady rate; capacity allows short bursts
        - Return 429 with Retry-After when the bucket is empty
        """),
        (.openai, "gpt-4o-mini", "STAR story", """
        At my last company our public API got hammered by one partner's retry loop. I added a Redis-backed \
        token bucket per API key at the gateway, with a Lua script so the check-and-decrement was atomic.
        """),
    ]

    private func native<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().background(Color(nsColor: .windowBackgroundColor))
    }

    func testRenderLiveInterview() async throws {
        let (controller, timeline) = try liveController()
        for width: CGFloat in [1000, 700] {
            try await RenderHarness.render("native-live-\(Int(width))", size: CGSize(width: width, height: 1200), settle: 0.6) {
                native { InterviewLiveScreen(controller: controller, timeline: timeline) }
            }
        }
    }

    func testRenderSetupAndSummary() async throws {
        let setup = InterviewController()
        setup.candidateName = "Jordan Rivera"
        try await RenderHarness.render("native-setup", size: CGSize(width: 820, height: 900)) {
            native {
                InterviewSetupForm(controller: setup,
                                   readiness: DetectorReadiness(hasDeepgramKey: false, usableLineupCount: 2))
            }
        }
        let (controller, _) = try liveController()
        controller.end()
        try await RenderHarness.render("native-summary", size: CGSize(width: 820, height: 560)) {
            native { InterviewSummaryView(controller: controller) }
        }
        let report = try XCTUnwrap(controller.database.loadInterviewReport(id: controller.interview!.id))
        try await RenderHarness.render("native-report", size: CGSize(width: 820, height: 1300)) {
            native { ReportDetail(report: report) }
        }
    }

    func testRenderAnalyzeRecording() async throws {
        let analyzer = RecordingAnalyzer()
        try await RenderHarness.render("native-recording-setup", size: CGSize(width: 560, height: 420)) {
            AnalyzeRecordingView(analyzer: analyzer).background(Color(nsColor: .windowBackgroundColor))
        }
        var sample: [DeepgramWord] = []
        for index in 0..<30 {
            let isInterviewer = index % 3 == 0
            let start = Double(index)
            sample.append(DeepgramWord(word: "word", start: start, end: start + 0.3, confidence: 0.9,
                                       speaker: isInterviewer ? 0 : 1,
                                       punctuatedWord: isInterviewer ? "Question?" : "answer"))
        }
        let words = sample
        analyzer.transcribe = { _ in words }
        analyzer.start(file: URL(fileURLWithPath: "/tmp/interview.wav"), candidateName: "Ana", role: nil)
        for _ in 0..<100 where analyzer.step != .chooseSpeaker { try await Task.sleep(nanoseconds: 20_000_000) }
        try await RenderHarness.render("native-recording-speakers", size: CGSize(width: 560, height: 360)) {
            AnalyzeRecordingView(analyzer: analyzer).background(Color(nsColor: .windowBackgroundColor))
        }
    }

    func testRenderRoleEditorAndSettings() async throws {
        var role = RoleProfile(name: "Senior Backend Engineer", company: "Acme",
                               jobDescription: "We run a public payments API in Go and Postgres. You will own rate limiting, idempotency and the on-call rotation.")
        role.plannedQuestions = [
            PlannedQuestion(text: F.question, family: "System design", strongAnswer: "Token bucket or sliding window; shared state; 429s"),
            PlannedQuestion(text: "Tell me about the hardest outage you owned end to end.", family: "Behavioral", strongAnswer: ""),
        ]
        try await RenderHarness.render("native-role-editor", size: CGSize(width: 760, height: 1100)) {
            native { RoleEditor(role: role) }
        }
        try await RenderHarness.render("native-settings-keys", size: CGSize(width: 640, height: 560)) {
            native { KeysSettingsTab() }
        }
        try await RenderHarness.render("native-settings-detector", size: CGSize(width: 640, height: 560)) {
            native { DetectorSettingsTab() }
        }
        try await RenderHarness.render("native-settings-shortcuts", size: CGSize(width: 640, height: 560)) {
            native { ShortcutsSettingsTab() }
        }
        try await RenderHarness.render("native-settings-privacy", size: CGSize(width: 640, height: 640)) {
            native { PrivacySettingsTab() }
        }
    }
}
