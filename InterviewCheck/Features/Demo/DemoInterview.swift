import Foundation
import InterviewCheckKit

/// Plays DemoScript through a separate InterviewController with its own
/// temporary database: no microphone, no network, no effect on real reports.
@MainActor
final class DemoInterview: ObservableObject {
    @Published private(set) var timeline: InterviewTimeline
    @Published private(set) var controller: InterviewController
    @Published private(set) var isFinished = false
    /// The finished interview's report, once its last score is saved.
    @Published private(set) var report: InterviewReportData?
    /// One temporary folder for every run's database, removed with the demo.
    private let folder = NSTemporaryDirectory() + "interviewcheck-demo-\(UUID().uuidString)"
    private var feed: Task<Void, Never>?

    init() {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        (timeline, controller) = Self.makeInterview(in: folder)
    }

    /// A separate controller, timeline and database for one run.
    private static func makeInterview(in folder: String) -> (InterviewTimeline, InterviewController) {
        let timeline = InterviewTimeline()
        let settings = DetectorSettings(defaults: UserDefaults(suiteName: "interviewcheck.demo") ?? .standard)
        settings.requiresKeys = false
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        settings.lineup = [LineupEntry(provider: .openai, model: "gpt-5.2"),
                           LineupEntry(provider: .claude, model: "claude-sonnet-5"),
                           LineupEntry(provider: .openai, model: "gpt-4o-mini")]
        let path = (folder as NSString).appendingPathComponent("run-\(UUID().uuidString).sqlite")
        let controller = InterviewController(timeline: timeline, database: SessionDatabase(databasePath: path),
                                             settings: settings)
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.questionSettleDelay = 300_000_000
        // One card per prompt style: Full answer, Talking points, STAR story.
        controller.maxReferenceRuns = 3
        controller.roleProvider = {
            RoleProfile(name: "Senior Backend Engineer", company: "Demo Co",
                        jobDescription: "Payments API in Go and Postgres; owns reliability and rate limiting.")
        }
        controller.runner = ReferenceAnswerRunner(makeClient: { provider, model in
            DemoTextClient(provider: provider, model: model)
        })
        return (timeline, controller)
    }

    func start() {
        guard controller.phase == .setup else { return }
        isFinished = false
        report = nil
        controller.candidateName = "Jordan Rivera (demo)"
        controller.consentConfirmed = true
        controller.start()
        let script = DemoScript.words(origin: timeline.now)
        // This run's own timeline and controller: after Restart, a cancelled
        // run never touches the next one.
        let timeline = timeline, controller = controller
        feed = Task { @MainActor [weak self] in
            for (word, marksQuestion) in script {
                let wait = word.end - timeline.now
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                timeline.append([word])
                if marksQuestion { controller.markQuestion() }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            controller.answerDone()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            controller.end()
            // The report shows once the last answer's score is saved.
            for _ in 0..<40 where !controller.pendingScoring.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.report = controller.interview.flatMap { controller.database.loadInterviewReport(id: $0.id) }
            self.isFinished = true
        }
    }

    /// A fresh run. The old interview may still be scoring its last answer;
    /// that finishes in its own controller and database, out of sight.
    func restart() {
        stop()
        report = nil
        isFinished = false
        (timeline, controller) = Self.makeInterview(in: folder)
        start()
    }

    func stop() {
        feed?.cancel()
        if controller.phase == .live { controller.end() }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// Streams a canned answer the way a real model would.
struct DemoTextClient: DetectorTextGenerating {
    let provider: AIProviderType
    let model: String
    var chunkPause: UInt64 = 120_000_000
    /// Seconds before the first words, per style, like a real model's wait
    /// (none when chunks are not paced, as in tests).
    var thinkingTime: [TimeInterval] = [1.6, 1.0, 2.3]
    var label: String { DetectorModelNames.providerShort(provider, model: model) }

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        let question = user.components(separatedBy: "\n").last { !$0.isEmpty && $0 != "Respond now." } ?? user
        let style = Self.style(system: system)
        if chunkPause > 0, style < thinkingTime.count {
            try await Task.sleep(nanoseconds: UInt64(thinkingTime[style] * 1_000_000_000))
        }
        let answer = DemoScript.aiAnswer(question: user.contains("Speaker 1:") ? user : question, runIndex: style)
        let words = answer.split(separator: " ")
        var sent = ""
        for (index, word) in words.enumerated() {
            let chunk = (index == 0 ? "" : " ") + word
            sent += chunk
            onChunk(chunk)
            if index % 6 == 5, chunkPause > 0 { try await Task.sleep(nanoseconds: chunkPause) }
        }
        return sent
    }

    /// Which canned answer fits the prompt: 0 full answer (Copilot),
    /// 1 talking points, 2 STAR story.
    static func style(system: String) -> Int {
        let prompt = system.lowercased()
        if prompt.contains("talking points") { return 1 }
        if prompt.contains("situation, task") { return 2 }
        return 0
    }
}
