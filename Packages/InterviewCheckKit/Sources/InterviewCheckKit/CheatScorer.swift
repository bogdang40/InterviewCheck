import Foundation

/// Every tunable number behind the %, in one place for calibration.
public struct CheatScoreWeights: Equatable, Codable {
    public var timing = 0.35
    public var fluency = 0.20
    public var similarity = 0.25
    public var judge = 0.20
    /// Wording language models use and people rarely say; only counted when found.
    public var phrasing = 0.10
    /// Answers shorter than this get low confidence.
    public var minimumWordsForConfidence = 40
    /// Answers at least this long, with references and the judge, can be high confidence.
    public var wordsForHighConfidence = 60
    /// The detector never claims certainty: shown scores stop here.
    public var maximumPercent = 95
    /// An answer this short, or one judged on its pause alone, stays below
    /// "mixed signs": a pause is not enough to call anything AI help.
    public var shortAnswerWords = 8
    public var timingOnlyMaximumPercent = 39

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
        phrasing = try container.decodeIfPresent(Double.self, forKey: .phrasing) ?? fallback.phrasing
        minimumWordsForConfidence = try container.decodeIfPresent(Int.self, forKey: .minimumWordsForConfidence)
            ?? fallback.minimumWordsForConfidence
        wordsForHighConfidence = try container.decodeIfPresent(Int.self, forKey: .wordsForHighConfidence)
            ?? fallback.wordsForHighConfidence
        maximumPercent = try container.decodeIfPresent(Int.self, forKey: .maximumPercent) ?? fallback.maximumPercent
        shortAnswerWords = try container.decodeIfPresent(Int.self, forKey: .shortAnswerWords) ?? fallback.shortAnswerWords
        timingOnlyMaximumPercent = try container.decodeIfPresent(Int.self, forKey: .timingOnlyMaximumPercent)
            ?? fallback.timingOnlyMaximumPercent
    }
}

public enum ScoreConfidence: String, Codable, Equatable {
    case low, medium, high
}

/// Each signal's value (0...1) before weighting; nil when the signal did
/// not apply. Kept with every score so weights can be re-tuned later.
public struct ScoreComponents: Codable, Equatable {
    public var timing: Double?
    public var fluency: Double?
    public var similarity: Double?
    public var judge: Double?
    /// Present only when AI wording was found (see PhrasingSignal).
    public var phrasing: Double?

    public init(timing: Double? = nil, fluency: Double? = nil, similarity: Double? = nil, judge: Double? = nil,
                phrasing: Double? = nil) {
        self.timing = timing
        self.fluency = fluency
        self.similarity = similarity
        self.judge = judge
        self.phrasing = phrasing
    }
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
    public let phrasing: PhrasingResult?
    public let components: ScoreComponents
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
        phrasing: PhrasingResult? = nil,
        hasTimingGap: Bool,
        weights: CheatScoreWeights = .default,
        measuresFluency: Bool = true,
        fallbackFollowUps: [String] = []
    ) -> AnswerScore {
        // A meeting transcript spreads words evenly over each line: its pace
        // and fillers say nothing, so fluency is left out entirely.
        let fluencyResult = measuresFluency ? fluency : fluency.unmeasured
        let components = Self.components(timing: timing, fluency: fluencyResult, similarity: similarity, judge: judge,
                                         phrasing: phrasing)
        var percent = Int((blend(components, weights: weights) * 100).rounded())
        let onlyTiming = components.fluency == nil && components.similarity == nil && components.judge == nil
            && components.phrasing == nil
        let tooShort = fluency.wordCount < weights.shortAnswerWords
        if onlyTiming || tooShort { percent = min(percent, weights.timingOnlyMaximumPercent) }

        let hasReferences = similarity?.best != nil
        let confidence: ScoreConfidence
        if fluency.wordCount < weights.minimumWordsForConfidence || hasTimingGap || (!hasReferences && judge == nil) {
            confidence = .low
        } else if fluency.wordCount >= weights.wordsForHighConfidence && hasReferences && judge != nil {
            confidence = .high
        } else {
            confidence = .medium
        }

        var notes = ScoreNotes.build(timing: timing, fluency: fluencyResult, similarity: similarity, judge: judge,
                                     phrasing: phrasing)
        if tooShort {
            notes.counterpoints.insert("Too short to judge: \(fluency.wordCount) word\(fluency.wordCount == 1 ? "" : "s")", at: 0)
        } else if onlyTiming {
            notes.counterpoints.insert("Only the pause could be measured; a pause alone is not a sign of AI help", at: 0)
        }
        return AnswerScore(
            percent: min(max(percent, 0), weights.maximumPercent),
            confidence: confidence,
            reasons: notes.reasons,
            counterpoints: notes.counterpoints,
            // The AI review's follow-ups when there is one; otherwise probes from the answer itself.
            followUps: judge.map(\.followUpQuestions).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackFollowUps,
            timing: timing,
            fluency: fluencyResult,
            similarity: similarity,
            judge: judge,
            phrasing: phrasing,
            components: components
        )
    }

    /// Each signal's contribution before weighting.
    public static func components(timing: TimingResult, fluency: FluencyResult,
                                  similarity: SimilarityResult?, judge: JudgeResult?,
                                  phrasing: PhrasingResult? = nil) -> ScoreComponents {
        let fluencyValue = fluency.isReliable ? fluency.score : 0.5
        return ScoreComponents(
            timing: timing.firstWordLatency == nil ? nil : timing.score * (0.5 + 0.5 * fluencyValue),
            fluency: fluency.isReliable ? fluency.score : nil,
            similarity: similarity?.best == nil ? nil : similarity?.score,
            judge: judge?.score,
            // Wording only speaks up when it finds something: its absence is no evidence.
            phrasing: (phrasing?.score ?? 0) >= PhrasingSignal.countsFrom ? phrasing?.score : nil
        )
    }

    /// Weighted average of the signals that applied (0...1).
    public static func blend(_ components: ScoreComponents, weights: CheatScoreWeights) -> Double {
        let parts: [(Double, Double?)] = [(weights.timing, components.timing), (weights.fluency, components.fluency),
                                          (weights.similarity, components.similarity), (weights.judge, components.judge),
                                          (weights.phrasing, components.phrasing)]
        let present = parts.compactMap { weight, value in value.map { (weight, $0) } }
        let total = present.reduce(0) { $0 + $1.0 }
        return total > 0 ? present.reduce(0) { $0 + $1.0 * $1.1 } / total : 0
    }
}

/// Turns the measurements into short sentences an interviewer can read at
/// a glance.
public enum ScoreNotes {
    public static func build(
        timing: TimingResult,
        fluency: FluencyResult,
        similarity: SimilarityResult?,
        judge: JudgeResult?,
        phrasing: PhrasingResult? = nil
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
                // The highlighted words show which; the line says how many.
                if let shared = similarity.bestShared, shared.sharedCount >= SharedWords.minimumRun {
                    reasons.append((similarity.score,
                                    "Matches the \(best.label) word for word: \(shared.sharedCount) of \(shared.answerCount) words"))
                } else {
                    reasons.append((similarity.score, "Closely follows the \(best.label) in meaning and order"))
                }
            } else if similarity.score < 0.15 {
                counterpoints.append("Wording is their own, not close to any AI answer")
            }
        }

        if let judge {
            for line in judge.evidence.prefix(2) {
                reasons.append((judge.score * 0.9, line))
            }
        }

        if let phrasing, phrasing.score >= PhrasingSignal.countsFrom, !phrasing.tells.isEmpty {
            let said = phrasing.tells.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            reasons.append((phrasing.score * 0.8, "Sounds written, not spoken: \(said)"))
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
