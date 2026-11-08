import SwiftUI

/// Optional constraints and assumptions for the next question, folded
/// behind one ghost button.
struct QuickAssistExtraContextDisclosure: View {
    @Binding var extraContext: String
    @Binding var isExpanded: Bool
    let isLoading: Bool

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private var characterCount: Int {
        extraContext.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    withAnimation(DesignTokens.Motion.sectionExpand) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(OverlayType.monoMicro)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(isExpanded ? "Hide extra context" : "Add extra context")
                    }
                }
                .buttonStyle(.overlay(.ghost, size: .small))
                .disabled(isLoading)

                if characterCount > 0 {
                    CountPill(value: characterCount, label: "chars")
                }
                Spacer(minLength: 0)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    FieldLabel(text: "Extra context")
                    TextField(
                        "",
                        text: $extraContext,
                        prompt: Text("Constraints, assumptions, or details about the interview").foregroundStyle(OverlayPalette.textTertiary),
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .focused($isFocused)
                    .disabled(isLoading)
                    .overlayField(isFocused: isFocused)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: isEnabled) { _, active in
            if !active { isFocused = false }
        }
        .onDisappear { isFocused = false }
    }
}
