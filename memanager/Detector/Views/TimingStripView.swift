import SwiftUI

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

struct TimingStripView: View {
    let model: TimingStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let scale = proxy.size.width / model.duration
                ZStack(alignment: .leading) {
                    Capsule().fill(OverlayPalette.well)
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(segment.kind))
                            .frame(width: max(2, CGFloat(min(segment.end, model.duration) - segment.start) * scale))
                            .offset(x: CGFloat(segment.start) * scale)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack(spacing: DesignTokens.Spacing.md) {
                Text(model.summary)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                Spacer(minLength: 0)
                legend("Silence", .silence)
                legend("Stalling", .stall)
                legend("Answer", .speech)
            }
        }
    }

    private func legend(_ title: String, _ kind: TimingStripModel.Segment.Kind) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(kind)).frame(width: 7, height: 7)
            Text(title).font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
        }
    }

    private func color(_ kind: TimingStripModel.Segment.Kind) -> Color {
        switch kind {
        case .silence: return OverlayPalette.warning.opacity(0.55)
        case .stall: return OverlayPalette.textTertiary.opacity(0.6)
        case .speech: return OverlayPalette.accent
        }
    }
}
