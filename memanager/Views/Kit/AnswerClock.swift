import SwiftUI

/// Pure timing rules for the answer clock so thresholds can be tested.
struct AnswerClockPolicy: Equatable {
    var warningAfter: TimeInterval = 60
    var criticalAfter: TimeInterval = 90

    func tone(forElapsed elapsed: TimeInterval) -> OverlayTone {
        if elapsed >= criticalAfter { return .critical }
        if elapsed >= warningAfter { return .warning }
        return .neutral
    }

    func progress(forElapsed elapsed: TimeInterval) -> Double {
        guard criticalAfter > 0 else { return 0 }
        return min(max(elapsed / criticalAfter, 0), 1)
    }

    static func label(forElapsed elapsed: TimeInterval) -> String {
        let total = max(Int(elapsed.rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Elapsed time since an answer settled. Interviewers lose focus after
/// about ninety seconds, so the clock turns amber at sixty and red at
/// ninety. Hidden until a start date is provided.
struct AnswerClock: View {
    let startedAt: Date?
    var policy = AnswerClockPolicy()

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                let tone = policy.tone(forElapsed: elapsed)
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(OverlayType.symbol(10))
                    Text(AnswerClockPolicy.label(forElapsed: elapsed))
                        .font(OverlayType.monoMicro)
                        .monospacedDigit()
                    ProgressTrack(progress: policy.progress(forElapsed: elapsed), tone: tone)
                        .frame(width: 44)
                }
                .foregroundStyle(tone == .neutral ? OverlayPalette.textTertiary : tone.color)
                .accessibilityLabel("Answer time \(AnswerClockPolicy.label(forElapsed: elapsed))")
            }
        }
    }
}

/// Thin horizontal progress track.
struct ProgressTrack: View {
    let progress: Double
    var tone: OverlayTone = .info
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(OverlayPalette.hairlineStrong)
                Capsule()
                    .fill(tone == .neutral ? OverlayPalette.textSecondary : tone.color)
                    .frame(width: max(geometry.size.width * progress, progress > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}
