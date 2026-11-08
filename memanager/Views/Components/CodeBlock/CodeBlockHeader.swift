import SwiftUI

/// The strip above the code rows: language, optional label, the new lines
/// badge when a step added some, and the copy button.
struct CodeBlockHeader: View {
    let language: String?
    let label: String?
    let newLinesLabel: String?
    let code: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(languageTitle)
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)

            if let label, !label.isEmpty {
                Text(label)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let newLinesLabel {
                ToneBadge(text: newLinesLabel, tone: .success, systemImage: "plus")
            }

            CodeBlockCopyButton(code: code)
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.trailing, DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var languageTitle: String {
        guard let language, !language.isEmpty else { return "Code" }
        return language
    }
}
