import SwiftUI

/// One debrief section: title with its tone dot, bulleted lines, and the
/// tone on the card edge.
struct DebriefSectionCard: View {
    let section: DebriefSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Circle()
                    .fill(section.tone == .neutral ? OverlayPalette.textSecondary : section.tone.color)
                    .frame(width: 6, height: 6)
                Text(section.title)
                    .font(OverlayType.heading)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Spacer(minLength: 0)
                CountBadge(count: section.lines.count)
            }
            if section.lines.isEmpty {
                Text("Nothing recorded.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        Circle()
                            .fill(section.tone == .neutral ? OverlayPalette.textTertiary : section.tone.color.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .padding(.top, DesignTokens.Spacing.sm)
                        Text(line)
                            .font(OverlayType.body)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .padding(.leading, DesignTokens.Spacing.xs)
        .toneEdgeCard(section.tone)
    }
}
