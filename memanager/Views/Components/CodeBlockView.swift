import SwiftUI

/// The one code block in the overlay. A language label and copy button sit
/// over per line rows, so line numbers stay aligned even when a long line
/// wraps, and a step can mark the range of lines it added as new.
///
/// An explicit code size is final. The default follows the user's reading size.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let showLineNumbers: Bool
    let fontSize: CGFloat?
    let label: String?
    let isHighlighted: Bool
    let highlightedLines: ClosedRange<Int>?

    @State private var highlighted: AttributedString?
    @ObservedObject private var settings = SettingsManager.shared

    private static let inlineHighlightLimit = 5000

    init(
        code: String,
        language: String? = nil,
        showLineNumbers: Bool = true,
        fontSize: CGFloat? = nil,
        label: String? = nil,
        isHighlighted: Bool = false,
        highlightedLines: ClosedRange<Int>? = nil
    ) {
        self.code = code
        self.language = language
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
        self.label = label
        self.isHighlighted = isHighlighted
        self.highlightedLines = highlightedLines
    }

    private struct HighlightKey: Equatable {
        let code: String
        let language: String?
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    }

    private var lines: [CodeLine] {
        if let highlighted {
            return CodeLineResolver.lines(from: highlighted, newRange: highlightedLines)
        }
        return CodeLineResolver.lines(from: code, newRange: highlightedLines)
    }

    var body: some View {
        let rows = lines
        let digits = CodeLineResolver.gutterDigits(lineCount: rows.count)

        VStack(alignment: .leading, spacing: 0) {
            CodeBlockHeader(
                language: language,
                label: label,
                newLinesLabel: CodeLineResolver.newLinesLabel(for: highlightedLines),
                code: code
            )
            Hairline()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { line in
                    CodeBlockLineRow(line: line, gutterDigits: digits, showsNumber: showLineNumbers,
                                     fontSize: fontSize ?? (13 * settings.fontSize / 14))
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(OverlayPalette.well))
        .overlay(shape.stroke(isHighlighted ? OverlayPalette.accentStroke : OverlayPalette.hairline, lineWidth: 1))
        .clipShape(shape)
        .animation(DesignTokens.Motion.focus, value: isHighlighted)
        .task(id: HighlightKey(code: code, language: language)) {
            await loadHighlighting()
        }
    }

    /// Small blocks highlight inline; large ones hop off the main thread.
    /// Keyed on the code so a changed block never keeps stale colors.
    private func loadHighlighting() async {
        if code.count < Self.inlineHighlightLimit {
            highlighted = TokenAwareHighlighter.highlight(code: code, language: language)
            return
        }
        highlighted = nil
        let code = self.code
        let language = self.language
        let result = await Task.detached(priority: .userInitiated) {
            TokenAwareHighlighter.highlight(code: code, language: language)
        }.value
        guard !Task.isCancelled else { return }
        highlighted = result
    }
}
