import SwiftUI

/// One step of the spoken script: the narration, the code with the new
/// lines marked, and the spoken reading of those lines. Only the active
/// card reports its chunk count to the teleprompter.
struct ImplementationScriptCard: View {
    let step: ImplementationStep
    let fontSize: CGFloat
    let style: SpokenCodeFormatter.Style
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                NumberBadge(number: step.number, isActive: isActive, size: 22)
                Text(step.title)
                    .font(OverlayType.bodyStrong(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(2)
            }

            if !step.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    FieldLabel(text: "Say")
                    SpeakableChunksView(
                        text: step.reasoning,
                        fontSize: fontSize,
                        showChunkIndicators: true,
                        chunkTrackingMode: .teleprompter,
                        chunkCountReportingEnabled: isActive
                    )
                }
            }

            if !step.cumulativeCode.isEmpty {
                CodeBlockView(
                    code: step.cumulativeCode,
                    language: step.language,
                    fontSize: fontSize,
                    highlightedLines: step.addedLineRange
                )
            }

            SpokenCodeLinesView(lines: SpokenLineResolver.lines(for: step, style: style))
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(isActive ? .raised : .base, accentEdge: isActive)
    }
}
