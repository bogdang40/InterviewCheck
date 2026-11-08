import SwiftUI

/// The question input: a labelled field, Ask when there is text, the auto
/// side question, the extra context disclosure, and the context chips.
struct QuickAssistComposer: View {
    @Binding var question: String
    @Binding var extraContext: String
    @Binding var isExtraContextExpanded: Bool
    let contextHints: [QuickAssistComposerContextHint]
    let contextStatusMessage: String?
    let isLoading: Bool
    let questionFocus: FocusState<Bool>.Binding
    let onAsk: () -> Void
    let onAutoSideQuestion: () -> Void

    private var hasQuestion: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: "Question")

            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                TextField(
                    "",
                    text: $question,
                    prompt: Text("Ask about this answer, an edge case, or what to say next").foregroundStyle(OverlayPalette.textTertiary),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .focused(questionFocus)
                .disabled(isLoading)
                .onSubmit {
                    guard !isLoading, hasQuestion else { return }
                    onAsk()
                }
                .overlayField(isFocused: questionFocus.wrappedValue)

                if hasQuestion {
                    Button("Ask", action: onAsk)
                        .buttonStyle(.overlayPrimary)
                        .disabled(isLoading)
                        .help("Ask this question")
                        .transition(.opacity)
                }

                Button(action: onAutoSideQuestion) {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.overlayIcon(size: 28))
                .disabled(isLoading)
                .help("Ask the most useful follow up for me (\(ShortcutCatalog.quickAssistAutoSideQuestion))")
                .accessibilityLabel("Ask the most useful follow up for me")
            }
            .animation(DesignTokens.Motion.focus, value: hasQuestion)

            QuickAssistComposerContextChips(hints: contextHints, contextStatusMessage: contextStatusMessage)

            QuickAssistExtraContextDisclosure(
                extraContext: $extraContext,
                isExpanded: $isExtraContextExpanded,
                isLoading: isLoading
            )
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.raised)
    }
}
