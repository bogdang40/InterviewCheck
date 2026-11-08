import SwiftUI

enum MarkdownTextRenderMode {
    case rich
    case preserveWhitespace
}

/// Markdown as overlay text. Rich mode rebuilds headings, lists, quotes and
/// fenced code as real blocks; whitespace preserving mode keeps the line
/// structure of the source and only styles inline code and links. Both
/// parses are memoized because blocks render again on every streaming pass.
struct MarkdownText: View {
    let text: String
    let renderMode: MarkdownTextRenderMode
    let fontSize: CGFloat?

    private static let parseCache = MemoizedParse<AttributedString>(capacity: 64)
    private static let blockCache = MemoizedParse<[MarkdownBlock]>(capacity: 64)

    init(_ text: String, renderMode: MarkdownTextRenderMode = .rich, fontSize: CGFloat? = nil) {
        self.text = text
        self.renderMode = renderMode
        self.fontSize = fontSize
    }

    var body: some View {
        switch renderMode {
        case .rich:
            richBody
        case .preserveWhitespace:
            singleText(Self.makeAttributedString(from: text, renderMode: .preserveWhitespace))
        }
    }

    @ViewBuilder
    private var richBody: some View {
        let blocks = Self.makeBlocks(from: text)
        if blocks.count == 1, case .paragraph = blocks[0].kind {
            singleText(blocks[0].content)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, fontSize: fontSize)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleText(_ content: AttributedString) -> some View {
        Text(content)
            .font(fontSize.map { OverlayType.body($0) })
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func makeBlocks(from text: String) -> [MarkdownBlock] {
        blockCache.value(for: text) { source in
            MarkdownBlockResolver.blocks(from: makeAttributedString(from: source, renderMode: .rich))
        }
    }

    static func makeAttributedString(
        from text: String,
        renderMode: MarkdownTextRenderMode = .rich
    ) -> AttributedString {
        let cacheKey = (renderMode == .rich ? "r|" : "w|") + text
        return parseCache.value(for: cacheKey) { _ in
            MarkdownInlineStyler.styled(buildAttributedString(from: text, renderMode: renderMode))
        }
    }

    /// The inline only mode keeps whitespace but leaves list markers as
    /// literal characters; swap them for real bullets so lists read as lists.
    static func normalizeListMarkers(_ text: String) -> String {
        guard text.contains("- ") || text.contains("* ") else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let content = line.drop(while: { $0 == " " })
                let indent = line.prefix(line.count - content.count)
                if content.hasPrefix("- ") || content.hasPrefix("* ") {
                    return String(indent) + "\u{2022} " + String(content.dropFirst(2))
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    private static func buildAttributedString(
        from text: String,
        renderMode: MarkdownTextRenderMode
    ) -> AttributedString {
        switch renderMode {
        case .rich:
            if let fullMarkdown = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                return fullMarkdown
            }
            if let inlineMarkdown = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return inlineMarkdown
            }
        case .preserveWhitespace:
            let normalized = normalizeListMarkers(text)
            if let inlineMarkdown = try? AttributedString(
                markdown: normalized,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return inlineMarkdown
            }
            if let fullMarkdown = try? AttributedString(
                markdown: normalized,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                return fullMarkdown
            }
        }
        return AttributedString(text)
    }
}
