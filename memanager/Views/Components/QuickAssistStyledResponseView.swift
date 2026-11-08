import SwiftUI

/// The settled answer: a prominent opener followed by open, icon-led rows.
/// The framework name decides which beat carries the emphasis caption.
struct QuickAssistStyledResponseView: View {
    let text: String
    let fontSize: CGFloat
    let markdownRenderMode: MarkdownTextRenderMode
    let renderSeed: String?
    let textColumnMaxWidth: CGFloat
    let mermaidHeight: CGFloat
    let mermaidActivation: MermaidActivation
    let mermaidStaggered: Bool
    let frameworkName: String?

    init(
        text: String,
        fontSize: CGFloat = 14,
        markdownRenderMode: MarkdownTextRenderMode = .rich,
        renderSeed: String? = nil,
        textColumnMaxWidth: CGFloat = 760,
        mermaidHeight: CGFloat = 360,
        mermaidActivation: MermaidActivation = .immediate,
        mermaidStaggered: Bool = false,
        frameworkName: String? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.markdownRenderMode = markdownRenderMode
        self.renderSeed = renderSeed
        self.textColumnMaxWidth = textColumnMaxWidth
        self.mermaidHeight = mermaidHeight
        self.mermaidActivation = mermaidActivation
        self.mermaidStaggered = mermaidStaggered
        self.frameworkName = frameworkName
    }

    /// Memoized so a body pass never re parses the whole response.
    private var sections: [QuickAssistSectionModel] {
        SectionParseStore.quickAssistSections.value(for: text, compute: QuickAssistSectionParser.parse)
    }

    var body: some View {
        let extraction = QuickAssistSayFirstExtractor.extract(from: sections)
        let beats = extraction.sections
        let plans = QuickAssistAnswerBeatResolver.plans(titles: beats.map(\.title), frameworkName: frameworkName)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let opener = extraction.opener {
                QuickAssistSayFirstCard(opener: opener, maxWidth: textColumnMaxWidth, bodyFontSize: fontSize)
            }
            ForEach(Array(beats.enumerated()), id: \.element.id) { index, section in
                if index > 0 { Hairline() }
                QuickAssistBeatCard(
                    section: section,
                    plan: plans[index],
                    fontSize: fontSize,
                    markdownRenderMode: markdownRenderMode,
                    renderSeed: renderSeed,
                    maxWidth: textColumnMaxWidth,
                    mermaidHeight: mermaidHeight,
                    mermaidActivation: mermaidActivation,
                    mermaidStaggered: mermaidStaggered
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
