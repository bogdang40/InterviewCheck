import SwiftUI

/// How a % reads at a glance. The words stay careful: a score is a signal
/// to follow up on, never a verdict.
enum ScoreBand: Equatable {
    case genuine, mixed, flagged

    init(percent: Int) {
        switch percent {
        case ..<40: self = .genuine
        case ..<70: self = .mixed
        default: self = .flagged
        }
    }

    var title: String {
        switch self {
        case .genuine: return "Looks like their own answer"
        case .mixed: return "Some signs of AI help"
        case .flagged: return "Strong signs of AI help"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .genuine: return .success
        case .mixed: return .warning
        case .flagged: return .critical
        }
    }
}

/// The score for one answer: %, confidence, reasons, and follow-ups.
struct ScoreCardView: View {
    let score: AnswerScoreRecord
    var compact = false

    private var band: ScoreBand { ScoreBand(percent: score.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                Text("\(score.percent)%")
                    .font(.system(size: compact ? 28 : 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(band.tone.color)
                    .monospacedDigit()
                    .accessibilityLabel("\(score.percent) percent likely AI-assisted")
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.title)
                        .font(OverlayType.title)
                        .foregroundStyle(OverlayPalette.textPrimary)
                    HStack(spacing: 6) {
                        ToneBadge(text: "\(score.confidence.rawValue.capitalized) confidence",
                                  tone: score.confidence == .low ? .neutral : .info)
                        if !score.isFinal { ToneBadge(text: "Live estimate", tone: .neutral, style: .outline) }
                        if score.metrics.timingGap { ToneBadge(text: "Audio gap", tone: .warning) }
                    }
                }
                Spacer(minLength: 0)
            }

            if !score.reasons.isEmpty {
                bulletList("Why", score.reasons, symbol: "exclamationmark.circle", tone: band == .genuine ? .neutral : band.tone)
            }
            if !score.counterpoints.isEmpty {
                bulletList("In their favour", score.counterpoints, symbol: "checkmark.circle", tone: .success)
            }
            if !score.followUps.isEmpty && !compact {
                bulletList("Ask next", score.followUps, symbol: "arrow.turn.down.right", tone: .info)
            }
            Text("A signal to follow up on, not proof. Ask a follow-up before deciding.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .padding(DesignTokens.Spacing.lg)
        .overlayCard(.base, stroke: band == .genuine ? nil : band.tone.stroke)
    }

    private func bulletList(_ title: String, _ items: [String], symbol: String, tone: OverlayTone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: title)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(OverlayType.symbol(11))
                        .foregroundStyle(tone.color)
                    Text(item)
                        .font(OverlayType.body)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
