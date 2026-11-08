import SwiftUI

/// Lays out one markdown block. Paragraph text inherits the caller's font
/// unless a reading size is given; headings step up from it, lists hang
/// their markers in a gutter, quotes get the accent edge, and fenced code
/// goes to the unified code block.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat?

    private static let headingStep: CGFloat = 2
    private static let markerWidth: CGFloat = 16
    private static let fallbackCodeSize: CGFloat = 13

    var body: some View {
        switch block.kind {
        case .paragraph:
            text
                .font(fontSize.map { OverlayType.body($0) })
        case .heading(let level):
            text
                .font(headingFont(level: level))
                .foregroundStyle(OverlayPalette.textPrimary)
                .padding(.top, DesignTokens.Spacing.xs)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(marker)
                    .font(fontSize.map { OverlayType.body($0) } ?? OverlayType.body)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .frame(minWidth: Self.markerWidth, alignment: .trailing)
                text
                    .font(fontSize.map { OverlayType.body($0) })
            }
            .padding(.leading, CGFloat(depth - 1) * DesignTokens.Spacing.lg)
        case .blockQuote:
            text
                .font(fontSize.map { OverlayType.body($0) })
                .foregroundStyle(OverlayPalette.textSecondary)
                .padding(.leading, DesignTokens.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlayCard(
                    .base,
                    cornerRadius: DesignTokens.Radius.md,
                    padding: DesignTokens.Spacing.md,
                    accentEdge: true
                )
        case .codeBlock(let language):
            CodeBlockView(
                code: String(block.content.characters),
                language: FencedMarkdownLanguageClassifier.primaryLanguage(from: language),
                fontSize: fontSize ?? Self.fallbackCodeSize
            )
        }
    }

    private var text: Text {
        Text(block.content)
    }

    private func headingFont(level: Int) -> Font {
        if let fontSize {
            let boost = level <= 2 ? Self.headingStep * 2 : Self.headingStep
            return OverlayType.bodyStrong(fontSize + boost)
        }
        return level <= 2 ? OverlayType.title : OverlayType.heading
    }
}
