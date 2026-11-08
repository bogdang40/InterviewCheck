import Foundation

/// Produces a `PacingReading` from the last N seconds of transcript.
///
/// The sampler is decoupled from `PacingDirector` so it can be unit-tested
/// against synthetic transcript sequences without any Combine plumbing. It
/// owns no singletons and no timer: the director drives evaluation cadence.
protocol PacingSampling {
    func evaluate(entries: [TranscriptEntry], now: Date) -> PacingReading
}

final class PacingSampler: PacingSampling {
    private let windowDuration: TimeInterval
    private let silenceFloor: TimeInterval

    init(windowDuration: TimeInterval = 60, silenceFloor: TimeInterval = 0.75) {
        self.windowDuration = windowDuration
        self.silenceFloor = silenceFloor
    }

    func evaluate(entries: [TranscriptEntry], now: Date) -> PacingReading {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let window = entries.filter { $0.timestamp >= cutoff }
        guard !window.isEmpty else {
            return PacingReading(
                timestamp: now,
                interviewerWordsPerMinute: nil,
                candidateWordsPerMinute: nil,
                interviewerQuestionCount: 0,
                interviewerUtteranceCount: 0,
                avgInterviewerUtteranceGapSeconds: nil,
                trailingSilenceSeconds: trailingSilence(entries: entries, now: now),
                sampleSize: 0
            )
        }

        let interviewer = window.filter { !$0.speaker.isMe }
        let candidate = window.filter { $0.speaker.isMe }

        return PacingReading(
            timestamp: now,
            interviewerWordsPerMinute: wordsPerMinute(entries: interviewer, windowSeconds: windowDuration),
            candidateWordsPerMinute: wordsPerMinute(entries: candidate, windowSeconds: windowDuration),
            interviewerQuestionCount: questionCount(entries: interviewer),
            interviewerUtteranceCount: interviewer.count,
            avgInterviewerUtteranceGapSeconds: averageGap(entries: interviewer),
            trailingSilenceSeconds: trailingSilence(entries: entries, now: now),
            sampleSize: window.count
        )
    }

    // MARK: - Helpers

    private func wordsPerMinute(entries: [TranscriptEntry], windowSeconds: TimeInterval) -> Double? {
        guard !entries.isEmpty else { return nil }
        let totalWords = entries.reduce(0) { total, entry in
            total + entry.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        let minutes = windowSeconds / 60.0
        guard minutes > 0 else { return nil }
        return Double(totalWords) / minutes
    }

    private func questionCount(entries: [TranscriptEntry]) -> Int {
        entries.reduce(0) { total, entry in
            total + entry.text.filter { $0 == "?" }.count
        }
    }

    private func averageGap(entries: [TranscriptEntry]) -> Double? {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return nil }
        var gaps: [TimeInterval] = []
        gaps.reserveCapacity(sorted.count - 1)
        for i in 1..<sorted.count {
            let gap = sorted[i].timestamp.timeIntervalSince(sorted[i - 1].timestamp)
            if gap >= silenceFloor {
                gaps.append(gap)
            }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    private func trailingSilence(entries: [TranscriptEntry], now: Date) -> TimeInterval {
        guard let last = entries.last else { return 0 }
        return max(0, now.timeIntervalSince(last.timestamp))
    }
}
