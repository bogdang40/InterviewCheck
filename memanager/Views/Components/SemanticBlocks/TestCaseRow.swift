import SwiftUI

/// One test case as a row to read aloud: the input, an arrow, the expected
/// value in the group's tone, and the reason underneath.
struct TestCaseRow: View {
    let testCase: TestCase
    let tone: OverlayTone

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(testCase.input)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Image(systemName: "arrow.right")
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)

                expectation
            }

            if let reasoning = testCase.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reasoning.isEmpty {
                Text(reasoning)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var expectation: some View {
        if TestExpectationPresenter.fitsChip(testCase.expected) {
            ToneBadge(text: testCase.expected, tone: tone, monospaced: true)
        } else {
            Text(testCase.expected)
                .font(OverlayType.mono)
                .foregroundStyle(tone.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
