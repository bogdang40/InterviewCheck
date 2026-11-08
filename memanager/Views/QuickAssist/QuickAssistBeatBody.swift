import SwiftUI

/// The blocks inside one beat: talking points as markdown, fenced code,
/// and mermaid diagrams with their staggered render slots.
struct QuickAssistBeatBody: View {
    let section: QuickAssistSectionModel
    let fontSize: CGFloat
    let markdownRenderMode: MarkdownTextRenderMode
    let renderSeed: String?
    let maxWidth: CGFloat
    let mermaidHeight: CGFloat
    let mermaidActivation: MermaidActivation
    let mermaidStaggered: Bool

    var body: some View {
        ForEach(Array(section.contentBlocks.enumerated()), id: \.element.id) { blockIndex, block in
            switch block {
            case .markdown(_, let value):
                MarkdownText(value, renderMode: markdownRenderMode, fontSize: fontSize)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .code(_, let languageHint, let code):
                FencedMarkdownBlockView(
                    languageHint: languageHint,
                    code: code,
                    fontSize: fontSize,
                    mermaidHeight: block.presentationKind == .mermaid ? mermaidHeight : 300,
                    mermaidRenderPolicy: mermaidRenderPolicy(for: blockIndex),
                    mermaidDisplayMode: .adaptiveQuickAssist,
                    mermaidRenderSeed: mermaidRenderSeed(for: blockIndex),
                    mermaidActivation: mermaidActivation
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func mermaidRenderSeed(for blockIndex: Int) -> String? {
        guard let renderSeed else { return nil }
        return "\(renderSeed)-s\(section.id)-b\(blockIndex)"
    }

    /// Staggered contexts give every diagram its own scheduler slot so the
    /// webviews boot one at a time instead of storming at stream settle.
    private func mermaidRenderPolicy(for blockIndex: Int) -> MermaidRenderPolicy {
        guard mermaidStaggered else { return .immediate }
        let slotID = mermaidRenderSeed(for: blockIndex) ?? "quick-assist-s\(section.id)-b\(blockIndex)"
        return .systemDesignAdaptiveSerial(slotID: slotID)
    }
}
