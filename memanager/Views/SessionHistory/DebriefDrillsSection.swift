import SwiftUI

/// Drills recommended by the debrief, each with a Practice this button
/// that seeds Quick Assist with the drill prompt and its transcript span.
struct DebriefDrillsSection: View {
    let drills: [SessionDrill]
    let onPractice: (SessionDrill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Drills", systemImage: "figure.run", count: drills.count, prominence: .heading)
            if drills.isEmpty {
                Text("No drills were recommended for this session.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(drills) { drill in
                        row(drill)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
    }

    private func row(_ drill: SessionDrill) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(drill.title)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    ToneBadge(text: drill.kind.displayLabel, tone: .neutral, style: .outline)
                }
                Text(drill.prompt)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Button("Practice this") {
                onPractice(drill)
            }
            .buttonStyle(.overlay(.secondary, size: .small))
        }
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }
}
