import Foundation

/// Every tunable number behind the %, in one place for calibration.
public struct CheatScoreWeights: Equatable, Codable {
    public var timing = 0.35
    public var fluency = 0.20
    public var similarity = 0.25
    public var judge = 0.20
    /// Answers shorter than this get low confidence.
    public var minimumWordsForConfidence = 40
    /// Answers at least this long, with references and the judge, can be high confidence.
    public var wordsForHighConfidence = 60
    /// The detector never claims certainty: shown scores stop here.
    public var maximumPercent = 95

    public static let `default` = CheatScoreWeights()

    public init() {}
}

extension CheatScoreWeights {
    /// Missing keys (from an older saved version) fall back to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CheatScoreWeights()
        timing = try container.decodeIfPresent(Double.self, forKey: .timing) ?? fallback.timing
        fluency = try container.decodeIfPresent(Double.self, forKey: .fluency) ?? fallback.fluency
        similarity = try container.decodeIfPresent(Double.self, forKey: .similarity) ?? fallback.similarity
        judge = try container.decodeIfPresent(Double.self, forKey: .judge) ?? fallback.judge
        minimumWordsForConfidence = try container.decodeIfPresent(Int.self, forKey: .minimumWordsForConfidence)
            ?? fallback.minimumWordsForConfidence
        wordsForHighConfidence = try container.decodeIfPresent(Int.self, forKey: .wordsForHighConfidence)
            ?? fallback.wordsForHighConfidence
        maximumPercent = try container.decodeIfPresent(Int.self, forKey: .maximumPercent) ?? fallback.maximumPercent
    }
}

public enum ScoreConfidence: String, Codable, Equatable {
    case low, medium, high
}

/// The % shown for one answer, with the reasons behind it.
public struct AnswerScore: Equatable {
    /// 0 ... 100.
    public let percent: Int
    public let confidence: ScoreConfidence
    /// Plain-language observations that raised the score, strongest first.
    public let reasons: [String]
    /// Observations that point to a genuine answer.
    public let counterpoints: [String]
    public let followUps: [String]
    public let timing: TimingResult
    public let fluency: FluencyResult
    public let similarity: SimilarityResult?
    public let judge: JudgeResult?
}

/// Combines the four signals. Timing only counts in full when the answer
/// that follows is fluent: a long pause and then halting speech is how
/// people think, a long pause and then a polished answer is how they read.
public enum CheatScorer {
    public static func score(
        timing: TimingResult,
        fluency: FluencyResult,
        similarity: SimilarityResult?,
        judge: JudgeResult?,
        hasTimingGap: Bool,
        weights: CheatScoreWeights = .default
    ) -> AnswerScore {
        var parts: [(weight: Double, value: Double)] = []
        let fluencyValue = fluency.isReliable ? fluency.score : 0.5
        if timing.firstWordLatency != nil {
            parts.append((weights.timing, timing.score * (0.5 + 0.5 * fluencyValue)))
        }
        if fluency.isReliable { parts.append((weights.fluency, fluency.score)) }
        if let similarity, similarity.best != nil { parts.append((weights.similarity, similarity.score)) }
        if let judge { parts.append((weights.judge, judge.score)) }

        let totalWeight = parts.reduce(0) { $0 + $1.weight }
        let blended = totalWeight > 0 ? parts.reduce(0) { $0 + $1.weight * $1.value } / totalWeight : 0
        let percent = Int((blended * 100).rounded())

        let hasReferences = similarity?.best != nil
        let confidence: ScoreConfidence
        if fluency.wordCount < weights.minimumWordsForConfidence || hasTimingGap || (!hasReferences && judge == nil) {
            confidence = .low
        } else if fluency.wordCount >= weights.wordsForHighConfidence && hasReferences && judge != nil {
            confidence = .high
        } else {
            confidence = .medium
        }

        let notes = ScoreNotes.build(timing: timing, fluency: fluency, similarity: similarity, judge: judge)
        return AnswerScore(
            percent: min(max(percent, 0), weights.maximumPercent),
            confidence: confidence,
            reasons: notes.reasons,
            counterpoints: notes.counterpoints,
            followUps: judge?.followUpQuestions ?? [],
            timing: timing,
            fluency: fluency,
            similarity: similarity,
            judge: judge
        )
    }
}

/// Turns the measurements into short sentences an interviewer can read at
/// a glance.
public enum ScoreNotes {
    public static func build(
        timing: TimingResult,
        fluency: FluencyResult,
        similarity: SimilarityResult?,
        judge: JudgeResult?
    ) -> (reasons: [String], counterpoints: [String]) {
        var reasons: [(Double, String)] = []
        var counterpoints: [String] = []

        if let latency = timing.substantiveLatency ?? timing.firstWordLatency {
            if latency >= 3 {
                let stall = timing.stallWordCount >= 3 ? ", filled with \u{201C}\(clip(timing.stallText))\u{201D}" : ""
                reasons.append((timing.score, "\(seconds(latency)) before the first real words\(stall)"))
            } else if latency < 2 {
                counterpoints.append("Started answering within \(seconds(latency))")
            }
        }

        if fluency.isReliable {
            if fluency.score >= 0.7 {
                let fillers = fluency.fillerCount == 0 ? "no \u{201C}um\u{201D} or \u{201C}uh\u{201D}"
                    : "only \(fluency.fillerCount) filler\(fluency.fillerCount == 1 ? "" : "s")"
                reasons.append((fluency.score, "\(fluency.wordCount) words with \(fillers) and a very even pace"))
            } else if fluency.score <= 0.45 {
                counterpoints.append("Natural hesitations: \(fluency.fillerCount) fillers, \(fluency.restartCount) restarts")
            }
        }

        if let similarity, let best = similarity.best {
            if similarity.score >= 0.4 {
                let phrases = best.sharedPhrases.prefix(2).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
                let detail = phrases.isEmpty ? "" : " (shared: \(phrases))"
                reasons.append((similarity.score, "Closely follows the \(best.label) answer\(detail)"))
            } else if similarity.score < 0.15 {
                counterpoints.append("Wording is their own, not close to any AI answer")
            }
        }

        if let judge {
            for line in judge.evidence.prefix(2) {
                reasons.append((judge.score * 0.9, line))
            }
        }

        let ordered = reasons.sorted { $0.0 > $1.0 }.map(\.1)
        var seen = Set<String>()
        let unique = ordered.filter { seen.insert($0).inserted }
        return (Array(unique.prefix(3)), Array(counterpoints.prefix(2)))
    }

    public static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }

    private static func clip(_ text: String) -> String {
        let words = text.split(separator: " ")
        return words.count > 6 ? words.prefix(6).joined(separator: " ") + "\u{2026}" : text
    }
}
