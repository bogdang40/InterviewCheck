import Foundation

/// The start of an answer on a time axis: silence after the question,
/// stalling words, then the real answer. Makes the "Cluely pause" visible.
struct TimingStripModel: Equatable {
    struct Segment: Equatable {
        enum Kind: Equatable { case silence, stall, speech }
        let kind: Kind
        let start: TimeInterval
        let end: TimeInterval
    }

    let segments: [Segment]
    let duration: TimeInterval
    let summary: String

    /// Builds the strip from the question end to the end of the answer's
    /// first `span` seconds.
    init(window: QuestionWindow, timing: TimingResult, now: TimeInterval, span: TimeInterval = 20) {
        let origin = window.questionEnd
        var segments: [Segment] = []
        var cursor = origin
        let words = window.answerWords
        let substantive = timing.substantiveIndex ?? (words.isEmpty ? nil : words.count)
        for (index, word) in words.enumerated() {
            if word.start - cursor >= 0.7 {
                segments.append(Segment(kind: .silence, start: cursor - origin, end: word.start - origin))
            }
            let kind: Segment.Kind = index < (substantive ?? 0) || word.isFiller ? .stall : .speech
            if let last = segments.last, last.kind == kind, word.start - origin - last.end < 0.7 {
                segments[segments.count - 1] = Segment(kind: kind, start: last.start, end: word.end - origin)
            } else {
                segments.append(Segment(kind: kind, start: word.start - origin, end: word.end - origin))
            }
            cursor = word.end
            if word.start - origin > span { break }
        }
        if words.isEmpty, now > origin {
            segments.append(Segment(kind: .silence, start: 0, end: now - origin))
        }
        self.segments = segments
        duration = max(min(max(segments.last?.end ?? 0, now - origin), span), 5)

        if let latency = timing.substantiveLatency {
            let stall = timing.stallWordCount > 0 ? ", \(timing.stallWordCount) stalling word\(timing.stallWordCount == 1 ? "" : "s")" : ""
            summary = "Real answer began \(ScoreNotes.seconds(latency)) after the question\(stall)"
        } else if let first = timing.firstWordLatency {
            summary = "First word \(ScoreNotes.seconds(first)) after the question"
        } else {
            summary = "Waiting for the candidate \u{00B7} \(ScoreNotes.seconds(max(0, now - origin)))"
        }
    }
}
