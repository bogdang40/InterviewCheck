import SwiftUI

/// Overview mode: a compact card per available section with its step count
/// and the title of its first step. Tapping a card jumps to Sections mode
/// with that section expanded.
struct DesignOverviewView: View {
    let content: SystemDesignContent
    let sections: [DesignSection]
    let onJump: (Int) -> Void

    @ObservedObject private var controller = SessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let steps = content.progressiveSteps(for: section.id)
                DesignOverviewCard(
                    section: section,
                    number: index + 1,
                    stepCount: steps.count,
                    firstStepTitle: steps.first?.title ?? "",
                    isCurrent: controller.systemDesignSectionIndex == index
                ) {
                    onJump(index)
                }
            }
        }
    }
}

struct DesignOverviewCard: View {
    let section: DesignSection
    let number: Int
    let stepCount: Int
    let firstStepTitle: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.md) {
                NumberBadge(
                    number: number,
                    color: DesignSectionToneResolver.color(for: section.id),
                    isActive: isCurrent
                )

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: section.symbol)
                            .font(OverlayType.callout)
                            .foregroundStyle(OverlayPalette.textSecondary)
                        Text(section.title)
                            .font(OverlayType.heading)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .lineLimit(1)
                    }
                    if !firstStepTitle.isEmpty {
                        Text("Starts with \(firstStepTitle)")
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                CountPill(value: stepCount, label: stepCount == 1 ? "step" : "steps")

                Image(systemName: "chevron.right")
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.md, padding: DesignTokens.Spacing.md, accentEdge: isCurrent)
        .help("Open \(section.title)")
    }
}
