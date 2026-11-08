import SwiftUI

/// The spoken attempt typed or pasted in, graded offline on demand. The
/// grader's verdict shows as a banner whose action records that grade.
struct PracticeAttemptEditor: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let evaluation: PracticeAttemptEvaluation?
    let onGrade: () -> Void
    let onRecord: (PracticeAttemptEvaluation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                FieldLabel(text: "Your attempt")
                Spacer(minLength: 0)
                Button("Review attempt", action: onGrade)
                    .buttonStyle(.overlay(.secondary, size: .small))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextEditor(text: $text)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused(focus)
                .frame(minHeight: 72, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste what you said out loud, then grade it.")
                            .font(OverlayType.body)
                            .foregroundStyle(OverlayPalette.textTertiary)
                            .padding(.top, DesignTokens.Spacing.xs)
                            .padding(.leading, DesignTokens.Spacing.xs)
                            .allowsHitTesting(false)
                    }
                }
                .overlayField(isFocused: focus.wrappedValue)
            if let evaluation {
                Text("Suggested review uses local text matching. It does not verify technical correctness; choose your own grade when needed.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                ToneBanner(
                    tone: evaluation.tone,
                    title: evaluation.title,
                    message: evaluation.feedback,
                    actions: [BannerAction(title: "Record \(PracticeGradeChoice.choice(for: evaluation.grade).title)", kind: .secondary) {
                        onRecord(evaluation)
                    }]
                )
            }
        }
    }
}
