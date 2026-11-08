import SwiftUI

/// One clarifying question: its number, the question at reading size, and
/// the assumption to fall back on when the interviewer has no preference.
struct QuestionRowView: View {
    let number: Int
    let question: Question
    let fontSize: CGFloat

    private static let numberWidth: CGFloat = 18

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Text("\(number)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(width: Self.numberWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(question.text)
                    .font(OverlayType.body(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let assumption = question.assumption?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !assumption.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        ToneBadge(text: "Assume", tone: .info)
                        Text(assumption)
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
