import Foundation
import InterviewCheckKit

/// One interview with one candidate.
struct InterviewRecord: Equatable, Identifiable {
    let id: String
    var workspaceID: String?
    var roleTitle: String
    var candidateName: String
    /// When the interviewer confirmed the candidate was told about
    /// transcription and checking. Nil means not confirmed.
    var consentConfirmedAt: Date?
    let startedAt: Date
    var endedAt: Date?
    /// Average score over answered questions, weighted by confidence.
    var overallPercent: Int?
    var flaggedCount: Int = 0
    var questionCount: Int = 0
    /// The app quit or crashed before the interview was ended; it was
    /// finished from the saved words at the next launch.
    var wasInterrupted = false
    /// "greenhouse:123" when the interview was prepared from a connector.
    var externalRef: String?
}

enum QuestionSource: String, Codable, Equatable {
    /// Picked from the role's planned questions.
    case planned
    /// Captured from what the interviewer said.
    case live
}

/// A question asked during an interview. Times are seconds since the
/// interview started.
struct InterviewQuestionRecord: Equatable, Identifiable {
    let id: String
    let interviewID: String
    var ordinal: Int
    var text: String
    var source: QuestionSource
    var markedAt: TimeInterval
    var questionEnd: TimeInterval?
    var answerStart: TimeInterval?
    var answerEnd: TimeInterval?
    var closedAt: TimeInterval?
    var answerText: String = ""
}

/// One AI answer generated for a question.
struct ReferenceAnswerRecord: Equatable, Identifiable {
    let id: String
    let questionID: String
    let provider: AIProviderType
    let model: String
    let promptName: String
    var text: String
    /// Seconds until the first full sentence arrived: how long a candidate
    /// reading from this tool would have had to wait.
    var firstSentenceSeconds: Double?
    var totalSeconds: Double?
    var error: String?
    var isStreaming = false

    var label: String { "\(DetectorModelNames.providerShort(provider, model: model)) · \(promptName)" }
}

/// The numbers behind a score, kept for the report.
struct AnswerMetrics: Codable, Equatable {
    var firstWordLatency: Double?
    var substantiveLatency: Double?
    var stallWords: Int
    var stallText: String
    var wordCount: Int
    var fillers: Int
    var restarts: Int
    var longPauses: Int
    var wordsPerMinute: Double
    var paceVariation: Double?
    var bestMatchLabel: String?
    var phraseContainment: Double?
    var semantic: Double?
    var sharedPhrases: [String]
    var referenceAgreement: Double?
    var judgeLikelihood: Int?
    var timingGap: Bool
    /// Each signal's value before weighting (absent on older scores).
    var components: ScoreComponents?

    init(score: AnswerScore, timingGap: Bool) {
        firstWordLatency = score.timing.firstWordLatency
        substantiveLatency = score.timing.substantiveLatency
        stallWords = score.timing.stallWordCount
        stallText = score.timing.stallText
        wordCount = score.fluency.wordCount
        fillers = score.fluency.fillerCount
        restarts = score.fluency.restartCount
        longPauses = score.fluency.longPauseCount
        wordsPerMinute = score.fluency.wordsPerMinute
        paceVariation = score.fluency.paceVariation
        bestMatchLabel = score.similarity?.best?.label
        phraseContainment = score.similarity?.best?.phraseContainment
        semantic = score.similarity?.best?.semantic
        sharedPhrases = score.similarity?.best?.sharedPhrases ?? []
        referenceAgreement = score.similarity?.referenceAgreement
        judgeLikelihood = score.judge?.likelihood
        self.timingGap = timingGap
        components = score.components
    }
}

/// A stored score for one answer.
struct AnswerScoreRecord: Equatable {
    let questionID: String
    let percent: Int
    let confidence: ScoreConfidence
    let reasons: [String]
    let counterpoints: [String]
    let followUps: [String]
    let metrics: AnswerMetrics
    /// False while the answer is still being given.
    let isFinal: Bool
}

extension DetectorModelNames {
    static func providerShort(_ provider: AIProviderType, model: String) -> String {
        switch provider {
        case .claude: return "Claude \(short(model))"
        case .openai: return "GPT \(short(model))"
        case .azureOpenAI: return "Azure \(model)"
        }
    }
}
