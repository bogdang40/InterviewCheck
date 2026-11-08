import SwiftUI

/// Expanded body of a step: the narration to say while typing, then the
/// cumulative code with the lines this step added marked as new.
struct ImplementationStepDetail: View {
    let step: ImplementationStep
    let fontSize: CGFloat
    let teleprompter: TeleprompterProgress?

    @State private var marksNewLines = true

    private static let toggleSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if !step.reasoning.isEmpty {
                narration
            }
            code
        }
    }

    private var narration: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                FieldLabel(text: "Say while typing")
                Spacer(minLength: 0)
                if let teleprompter {
                    ToneBadge(
                        text: ImplementationStepPresenter.teleprompterCaption(teleprompter),
                        tone: .info,
                        systemImage: "text.cursor"
                    )
                    KeyHint(label: "Next line", shortcut: ShortcutCatalog.nextChunk)
                } else {
                    KeyHint(label: "Teleprompter", shortcut: ShortcutCatalog.toggleTeleprompter)
                }
            }
            SpeakableChunksView(
                text: step.reasoning,
                fontSize: fontSize,
                showChunkIndicators: true,
                chunkTrackingMode: .teleprompter
            )
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                FieldLabel(text: "Code")
                Spacer(minLength: 0)
                if step.addedLineRange != nil {
                    Toggle("Mark new lines", isOn: $marksNewLines)
                    .toggleStyle(.checkbox)
                    .help(marksNewLines ? "Hide the new line marks" : "Mark the lines this step adds")
                    .accessibilityLabel("Mark new lines")
                }
            }
            CodeBlockView(
                code: step.cumulativeCode,
                language: step.language,
                fontSize: fontSize,
                highlightedLines: marksNewLines ? step.addedLineRange : nil
            )
            Text("Generated code · Not executed")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
    }
}
