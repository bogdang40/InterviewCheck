import SwiftUI

/// A single code row: the number in the gutter, a hairline, and the text
/// wrapping beside it. Rows the current step added carry the success tint
/// and a thin edge so the eye lands on what is new.
struct CodeBlockLineRow: View {
    let line: CodeLine
    let gutterDigits: Int
    let showsNumber: Bool
    var fontSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showsNumber {
                Text(String(line.number))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(line.isNew ? OverlayTone.success.color : OverlayPalette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: CGFloat(gutterDigits) * fontSize * 0.65, alignment: .trailing)
                    .padding(.trailing, DesignTokens.Spacing.sm)
                Hairline(axis: .vertical)
                    .padding(.trailing, DesignTokens.Spacing.sm)
            }
            Text(displayText)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 1)
        .background(line.isNew ? OverlayTone.success.tint : .clear)
        .overlay(alignment: .leading) {
            if line.isNew {
                Rectangle()
                    .fill(OverlayTone.success.color)
                    .frame(width: 2)
            }
        }
    }

    private var displayText: AttributedString {
        line.text.characters.isEmpty ? AttributedString(" ") : line.text
    }
}
