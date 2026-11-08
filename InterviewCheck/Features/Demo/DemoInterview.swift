import Foundation
import InterviewCheckKit

/// Plays DemoScript through a separate InterviewController with its own
/// temporary database: no microphone, no network, no effect on real reports.
@MainActor
final class DemoInterview: ObservableObject {
    let timeline = InterviewTimeline()
    let controller: InterviewController
    @Published private(set) var isFinished = false
    private let databasePath = NSTemporaryDirectory() + "interviewcheck-demo-\(UUID().uuidString).sqlite"
    private var feed: Task<Void, Never>?

    init() {
        let settings = DetectorSettings(defaults: UserDefaults(suiteName: "interviewcheck.demo") ?? .standard)
        settings.requiresKeys = false
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        settings.lineup = [LineupEntry(provider: .openai, model: "gpt-5.2"),
                           LineupEntry(provider: .claude, model: "claude-sonnet-5"),
                           LineupEntry(provider: .openai, model: "gpt-4o-mini")]
        controller = InterviewController(timeline: timeline, database: SessionDatabase(databasePath: databasePath),
                                         settings: settings)
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.questionSettleDelay = 300_000_000
        // One card per prompt style: Copilot, Talking points, STAR story.
        controller.maxReferenceRuns = 3
        controller.roleProvider = {
            RoleProfile(name: "Senior Backend Engineer", company: "Demo Co",
                         jobDescription: "Payments API in Go and Postgres; owns reliability and rate limiting.")
        }
        controller.runner = ReferenceAnswerRunner(makeClient: { provider, model in
            DemoTextClient(provider: provider, model: model)
        })
    }

    func start() {
        guard controller.phase == .setup else { return }
        isFinished = false
        controller.candidateName = "Jordan Rivera (demo)"
        controller.consentConfirmed = true
        controller.start()
        let script = DemoScript.words(origin: timeline.now)
        feed = Task { @MainActor [weak self] in
            for (word, marksQuestion) in script {
                guard let self, !Task.isCancelled else { return }
                let wait = word.end - self.timeline.now
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                self.timeline.append([word])
                if marksQuestion { self.controller.markQuestion() }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.controller.answerDone()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.controller.end()
            self.isFinished = true
        }
    }

    func restart() {
        stop()
        controller.reset()
        timeline.reset()
        start()
    }

    func stop() {
        feed?.cancel()
        if controller.phase == .live { controller.end() }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: databasePath)
    }
}

/// Streams a canned answer the way a real model would.
struct DemoTextClient: DetectorTextGenerating {
    let provider: AIProviderType
    let model: String
    var chunkPause: UInt64 = 120_000_000
    var label: String { DetectorModelNames.providerShort(provider, model: model) }

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        let question = user.components(separatedBy: "\n").last { !$0.isEmpty && $0 != "Respond now." } ?? user
        let style = Self.style(system: system)
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
