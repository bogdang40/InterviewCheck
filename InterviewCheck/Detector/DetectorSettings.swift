import Combine
import Foundation
import InterviewCheckKit

/// The detector's own settings, saved in UserDefaults.
@MainActor
final class DetectorSettings: ObservableObject {
    static let shared = DetectorSettings()

    /// Providers and models that produce the AI answers. Entries without a
    /// saved key are skipped at run time.
    @Published var lineup: [LineupEntry] { didSet { save(lineup, key: Keys.lineup) } }
    /// Provider and model that reviews each answer.
    @Published var judge: LineupEntry { didSet { save(judge, key: Keys.judge) } }
    @Published var judgeEnabled: Bool { didSet { defaults.set(judgeEnabled, forKey: Keys.judgeEnabled) } }
    /// Compare meaning with OpenAI embeddings (needs an OpenAI key).
    @Published var useEmbeddings: Bool { didSet { defaults.set(useEmbeddings, forKey: Keys.embeddings) } }
    /// Sentence the interviewer can read or paste to tell the candidate.
    @Published var consentNotice: String { didSet { defaults.set(consentNotice, forKey: Keys.notice) } }
    @Published var weights: CheatScoreWeights { didSet { save(weights, key: Keys.weights) } }

    static let defaultLineup = [
        LineupEntry(provider: .claude, model: "claude-sonnet-5"),
        LineupEntry(provider: .openai, model: "gpt-5.2"),
        LineupEntry(provider: .openai, model: "gpt-4o-mini"),
    ]
    static let defaultJudge = LineupEntry(provider: .claude, model: "claude-sonnet-5")
    static let defaultNotice = """
    Before we start: this interview is transcribed, and your answers are checked against \
    AI-generated answers to make sure the interview reflects your own thinking. \
    A person reviews the results; nothing is decided automatically.
    """

    private let defaults: UserDefaults

    private enum Keys {
        static let lineup = "interviewcheck.detector.lineup"
        static let judge = "interviewcheck.detector.judge"
        static let judgeEnabled = "interviewcheck.detector.judgeEnabled"
        static let embeddings = "interviewcheck.detector.embeddings"
        static let notice = "interviewcheck.detector.consentNotice"
        static let weights = "interviewcheck.detector.weights"
    }

    init(defaults: UserDefaults = TestRuntime.isRunningUnitTests ? DetectorSettings.testDefaults : .standard) {
        self.defaults = defaults
        lineup = Self.load([LineupEntry].self, key: Keys.lineup, from: defaults) ?? Self.defaultLineup
        judge = Self.load(LineupEntry.self, key: Keys.judge, from: defaults) ?? Self.defaultJudge
        judgeEnabled = defaults.object(forKey: Keys.judgeEnabled) as? Bool ?? true
        useEmbeddings = defaults.object(forKey: Keys.embeddings) as? Bool ?? true
        consentNotice = defaults.string(forKey: Keys.notice) ?? Self.defaultNotice
        weights = Self.load(CheatScoreWeights.self, key: Keys.weights, from: defaults) ?? .default
    }

    private static let testDefaults = UserDefaults(suiteName: "interviewcheck.tests.\(UUID().uuidString)")!

    /// Lineup entries whose provider has a saved key.
    func usableLineup(settings: SettingsManager = .shared) -> [LineupEntry] {
        lineup.filter { $0.isEnabled && !settings.apiKey(for: $0.provider).isEmpty }
    }

    /// The judge, or the first usable lineup entry when the judge has no key.
    func usableJudge(settings: SettingsManager = .shared) -> LineupEntry? {
        guard judgeEnabled else { return nil }
        if !settings.apiKey(for: judge.provider).isEmpty { return judge }
        return usableLineup(settings: settings).first
    }

    func restoreDefaults() {
        lineup = Self.defaultLineup
        judge = Self.defaultJudge
        judgeEnabled = true
        useEmbeddings = true
        consentNotice = Self.defaultNotice
        weights = .default
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
