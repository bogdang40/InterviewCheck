import SwiftUI

/// The raw response as it arrives, in a raised card clamped between 120
/// and 220 points so the structured sections below stay in reach.
struct DesignLiveStreamCard: View {
    let text: String
    let fontSize: CGFloat

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.accent)
                Text("Live response")
                    .font(OverlayType.captionStrong)
                    .foregroundStyle(OverlayPalette.textSecondary)
                Spacer(minLength: 0)
            }

            if hasText {
                StreamingTextWithCursor(
                    text: text,
                    fontSize: fontSize,
                    scrollTarget: .main,
                    programmaticFollowPolicy: .allowUserDetachment
                )
                .frame(minHeight: 120, maxHeight: 220)
            } else {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for the first response chunk.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.xl)
            }
        }
        .overlayCard(.raised, padding: DesignTokens.Spacing.md)
    }
}
