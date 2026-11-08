import SwiftUI

/// Every Quick Assist turn of the session with its verification status,
/// route, and tool calls.
struct ReplayEvidenceSection: View {
    let turns: [SessionReplayTurnEvidence]

    @State private var isExpanded = true

    var body: some View {
        DisclosureCard("Quick Assist evidence", systemImage: "bubble.left.and.bubble.right", count: turns.count, isExpanded: $isExpanded) {
            Text("Saved checks and tool traces describe the request. They do not independently establish answer correctness.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            if turns.isEmpty {
                Text("No Quick Assist turns were recorded for this session.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(turns, id: \.call.turnId) { turn in
                        row(turn)
                    }
                }
            }
        }
    }

    private func row(_ turn: SessionReplayTurnEvidence) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(ReplayPresentation.turnTitle(turn.call))
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.xs)
                ToneBadge(
                    text: turn.call.verificationStatus.displayLabel,
                    tone: turn.call.verificationStatus.tone,
                    systemImage: turn.call.verificationStatus.systemImage,
                    style: .outline
                )
            }
            Text(ReplayPresentation.turnMeta(turn))
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .lineLimit(1)
            if !turn.toolCalls.isEmpty {
                Text(turn.toolCalls.prefix(4).map(\.toolName).joined(separator: ", "))
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .toneEdgeCard(turn.call.verificationStatus.tone, level: .raised, cornerRadius: DesignTokens.Radius.md)
    }
}
