import Foundation

/// One quantitative snapshot of the interview cadence over a short window
/// (typically the last 60 seconds). Produced by `PacingSampler` and fused by
/// `PacingDirector`. Pure value type so it can be stored, diffed, and passed
/// across actors cheaply.
struct PacingReading: Equatable {
    let timestamp: Date
    let interviewerWordsPerMinute: Double?
    let candidateWordsPerMinute: Double?
    let interviewerQuestionCount: Int
    let interviewerUtteranceCount: Int
    let avgInterviewerUtteranceGapSeconds: Double?
    let trailingSilenceSeconds: Double
    let sampleSize: Int

    static let empty = PacingReading(
        timestamp: .distantPast,
        interviewerWordsPerMinute: nil,
        candidateWordsPerMinute: nil,
        interviewerQuestionCount: 0,
        interviewerUtteranceCount: 0,
        avgInterviewerUtteranceGapSeconds: nil,
        trailingSilenceSeconds: 0,
        sampleSize: 0
    )

    var hasInterviewerSignal: Bool {
        interviewerUtteranceCount > 0
    }
}
