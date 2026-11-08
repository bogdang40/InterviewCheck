import SwiftUI

/// Maps the pacing director's state onto a badge the user can read.
struct PacingBadgeModel: Equatable {
    let kind: PacingState.Kind
    let confidence: Double

    static let minimumConfidence = 0.25

    init?(state: PacingState, enabled: Bool) {
        guard enabled, state.confidence >= Self.minimumConfidence else { return nil }
        kind = state.kind
        confidence = state.confidence
    }

    var tone: OverlayTone {
        switch kind {
        case .decisive: return .warning
        case .measured: return .neutral
        case .expansive: return .success
        case .stalled: return .info
        }
    }

    var advice: String {
        switch kind {
        case .decisive: return "Keep it short"
        case .measured: return "Steady"
        case .expansive: return "Room to go deeper"
        case .stalled: return "Take the lead"
        }
    }
}

/// The band under the command bar that shows what was just asked, how
/// the room is pacing, and the one key that answers it.
struct LiveStrip: View {
    let question: LiveQuestion?
    let pacing: PacingBadgeModel?
    let onAnswer: () -> Void

    var body: some View {
        if let question {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ToneBadge(
                    text: question.isQuestion ? "Asked" : speakerLabel(question.speaker),
                    tone: question.isQuestion ? .info : .neutral,
                    systemImage: question.isQuestion ? "questionmark" : nil
                )

                Text(question.text)
                    .font(OverlayType.body)
                    .foregroundStyle(question.isPartial ? OverlayPalette.textSecondary : OverlayPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(question.text)

                if let pacing {
                    ToneBadge(text: pacing.advice, tone: pacing.tone, style: .outline)
                        .help(pacing.kind.accessibilityDescription)
                }

                Button(action: onAnswer) {
                    HStack(spacing: 5) {
                        Text("Answer")
                        KeyCap(shortcut: ShortcutCatalog.quickAssist)
                    }
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: OverlayLayout.liveStripHeight)
            .background(OverlayPalette.surface)
            .overlay(alignment: .bottom) { Hairline() }
            .transition(.opacity)
        }
    }

    private func speakerLabel(_ speaker: TranscriptSpeaker) -> String {
        switch speaker {
        case .me: return "You"
        case .speaker, .unknown: return speaker.displayName
        }
    }
}
