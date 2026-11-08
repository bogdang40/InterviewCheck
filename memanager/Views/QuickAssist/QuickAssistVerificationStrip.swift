import SwiftUI

/// Slim strip over the answer: verification dot and label, confidence,
/// unsupported claims, and the answer clock once the turn settles.
struct QuickAssistVerificationStrip: View {
    let model: QuickAssistVerificationStripModel
    let clockStartedAt: Date?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if model.isStreaming {
                StatusDot(state: model.dotState, size: 6)
            } else {
                QuickAssistVerificationDot(status: model.status, size: 7)
                    .frame(width: 12, height: 12)
            }
            ToneBadge(text: model.statusLabel, tone: model.tone, systemImage: model.systemImage)
            if let confidence = model.confidenceLabel {
                Text(confidence)
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .help("Verifier confidence")
            }
            if let unsupported = model.unsupportedLabel {
                ToneBadge(text: unsupported, tone: .warning, systemImage: "exclamationmark.triangle")
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            AnswerClock(startedAt: clockStartedAt)
        }
        .padding(.horizontal, OverlayLayout.stageInset)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .frame(minHeight: 30)
        .background(OverlayPalette.surface)
    }
}
