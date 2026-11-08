import SwiftUI

/// The labelled rows under a turn: verification, routing, latency, feedback.
struct TurnDeepDiveRows: View {
    let record: QuickAssistCallRecord

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("Checks describe recorded source and request signals, not factual correctness or executed code tests.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            row("Verification") {
                Image(systemName: record.verificationStatus.systemImage)
                    .foregroundStyle(record.verificationStatus.tone == .neutral ? OverlayPalette.textSecondary : record.verificationStatus.tone.color)
                Text(record.verificationStatus.displayLabel)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Text(TurnDeepDiveFormatter.percent(record.verificationConfidence))
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textSecondary)
                if let claims = TurnDeepDiveFormatter.claims(record.unsupportedClaimCount) {
                    ToneBadge(text: claims, tone: .warning)
                }
            }
            row("Routing") {
                Text(record.contextMode.rawValue)
                    .foregroundStyle(OverlayPalette.textPrimary)
                if let confidence = record.routeConfidence {
                    ProgressTrack(progress: confidence, tone: .info)
                        .frame(width: 48)
                    Text(TurnDeepDiveFormatter.percent(confidence))
                        .font(OverlayType.monoMicro)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
            }
            row("Latency") {
                Text(TurnDeepDiveFormatter.latency(record.durationMs))
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
            }
            row("Feedback") {
                Image(systemName: record.userFeedbackStatus.systemImage)
                    .foregroundStyle(record.userFeedbackStatus.tone == .neutral ? OverlayPalette.textSecondary : record.userFeedbackStatus.tone.color)
                Text(record.userFeedbackStatus.label)
                    .foregroundStyle(OverlayPalette.textPrimary)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(width: 76, alignment: .leading)
            content()
                .font(OverlayType.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.sm)
    }
}
