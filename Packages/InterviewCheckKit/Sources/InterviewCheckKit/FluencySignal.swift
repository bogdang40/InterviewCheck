import Foundation

/// How the answer sounds once it gets going.
public struct FluencyResult: Equatable {
    public let wordCount: Int
    public let fillerCount: Int
    public let restartCount: Int
    public let longPauseCount: Int
    public let wordsPerMinute: Double
    /// Spread of the speaking pace across 5-second windows (std / mean).
    /// Reading aloud is steady; thinking aloud speeds up and slows down.
    public let paceVariation: Double?
    /// 0 (halting, natural) ... 1 (steady, filler-free, read-like).
    public let score: Double
    /// Too few words to judge.
    public var isReliable: Bool { wordCount >= FluencySignal.minimumWords }
}

/// Reading-like delivery: almost no fillers or restarts, no long mid-answer
/// pauses, and an even pace. Measured over the first minute after the
/// substantive start, where reading from a tool is most visible.
public enum FluencySignal {
    public static let window: TimeInterval = 60
    public static let minimumWords = 25
    public static let longPause: TimeInterval = 1.5
    public static let paceBin: TimeInterval = 5

    public static func evaluate(answerWords: [TimedWord], from startIndex: Int?) -> FluencyResult {
        let start = startIndex ?? 0
        guard start < answerWords.count else { return empty }
        let origin = answerWords[start].start
        let words = answerWords[start...].filter { $0.start < origin + window }
        guard let last = words.last else { return empty }

        let spoken = words.filter { !$0.isFiller }
        let fillers = words.count - spoken.count
        let restarts = countRestarts(spoken.map(\.normalized))
        let pauses = zip(words, words.dropFirst()).filter { $1.start - $0.end >= longPause }.count
        let minutes = max((last.end - origin) / 60, 1.0 / 60)
        let wpm = Double(spoken.count) / minutes
        let variation = paceVariation(spoken, origin: origin)

        let per100 = 100 / Double(max(spoken.count, 1))
        let fillerTerm = 1 - min(Double(fillers) * per100 / 6, 1)
        let restartTerm = 1 - min(Double(restarts) * per100 / 4, 1)
        let pauseTerm = 1 - min(Double(pauses) / minutes / 4, 1)
        let steadyTerm = variation.map { 1 - min(max(($0 - 0.15) / 0.35, 0), 1) } ?? 0.5
        let score = 0.35 * fillerTerm + 0.2 * restartTerm + 0.2 * pauseTerm + 0.25 * steadyTerm

        return FluencyResult(
            wordCount: spoken.count, fillerCount: fillers, restartCount: restarts,
            longPauseCount: pauses, wordsPerMinute: wpm, paceVariation: variation, score: score
        )
    }

    private static var empty: FluencyResult {
        FluencyResult(wordCount: 0, fillerCount: 0, restartCount: 0, longPauseCount: 0,
                      wordsPerMinute: 0, paceVariation: nil, score: 0)
    }

    /// A word said twice in a row, or a two-word phrase repeated ("I would,
    /// I would"), marks a self-correction.
    public static func countRestarts(_ words: [String]) -> Int {
        var count = 0
        var index = 1
        while index < words.count {
            if words[index] == words[index - 1], !words[index].isEmpty {
                count += 1
            } else if index >= 3, words[index - 1] == words[index - 3], words[index] == words[index - 2] {
                count += 1
            }
            index += 1
        }
        return count
    }

    /// Coefficient of variation of words per 5-second bin; nil when there
    /// are fewer than three full bins.
    public static func paceVariation(_ words: [TimedWord], origin: TimeInterval) -> Double? {
        guard let last = words.last else { return nil }
        let binCount = Int((last.start - origin) / paceBin)
        guard binCount >= 3 else { return nil }
        var bins = Array(repeating: 0.0, count: binCount)
        for word in words {
            let bin = Int((word.start - origin) / paceBin)
            if bin < binCount { bins[bin] += 1 }
        }
        let mean = bins.reduce(0, +) / Double(bins.count)
        guard mean > 0 else { return nil }
        let variance = bins.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(bins.count)
        return variance.squareRoot() / mean
    }
}
