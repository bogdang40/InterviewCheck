import SwiftUI

/// One implementation step. Collapsed it is a numbered title with a one
/// line preview of the narration; expanded it is the narration to say
/// while typing followed by the code with the new lines marked.
struct ImplementationStepCard: View {
    let step: ImplementationStep
    let isExpanded: Bool
    let fontSize: CGFloat
    /// Teleprompter cursor, nil when teleprompter mode is off. Passed by the
    /// parent, which observes the controller, so this leaf stays a value.
    let teleprompter: TeleprompterProgress?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Hairline()
                ImplementationStepDetail(step: step, fontSize: fontSize, teleprompter: teleprompter)
                    .padding(DesignTokens.Spacing.md)
                    .transition(.opacity)
            }
        }
        .overlayCard(
            isExpanded ? .raised : .base,
            accentEdge: isExpanded,
            stroke: isExpanded ? OverlayPalette.accentStroke : nil
        )
        .animation(DesignTokens.Motion.sectionExpand, value: isExpanded)
    }

    private var header: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                NumberBadge(number: step.number, isActive: isExpanded, size: 22)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(step.title)
                        .font(isExpanded ? OverlayType.bodyStrong(fontSize) : OverlayType.body(fontSize))
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !isExpanded, let preview = ImplementationStepPresenter.preview(of: step) {
                        Text(preview)
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(step.number), \(step.title)")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }
}
