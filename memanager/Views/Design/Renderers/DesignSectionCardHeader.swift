import SwiftUI

/// The always visible row of a section card: numbered badge in the
/// section's color, the blueprint symbol and title, the current step
/// position, and the step budget badge.
struct DesignSectionCardHeader: View {
    let section: DesignSection
    let number: Int
    let total: Int
    let progress: DesignStepProgress
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            NumberBadge(
                number: number,
                color: DesignSectionToneResolver.color(for: section.id),
                isActive: isExpanded
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: section.symbol)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textSecondary)
                    Text(section.title)
                        .font(OverlayType.heading)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(progress.positionLabel)
                        .font(OverlayType.monoMicro)
                        .foregroundStyle(OverlayPalette.textTertiary)
                    ToneBadge(
                        text: progress.budgetLabel,
                        tone: progress.budgetTone,
                        systemImage: progress.isComplete ? "checkmark" : "exclamationmark"
                    )
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text("\(number)/\(total)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)

            Image(systemName: "chevron.right")
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }
}
