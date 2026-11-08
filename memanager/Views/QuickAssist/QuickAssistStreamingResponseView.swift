import SwiftUI

/// Progressive streaming renderer: the committed prefix of the draft is
/// styled through the SAME QuickAssistStyledResponseView used at settle
/// (ordinal section ids diff in place as the prefix grows), while only the
/// volatile tail renders as raw text with the caret. Mermaid blocks show
/// placeholders until the stream settles.
///
/// Content only: the hosting stage owns the one persistent scroll container
/// for the loading, streaming, and settled phases, so settling never tears
/// down the ScrollView or loses the reading position.
struct QuickAssistStreamingResponseView: View {
    let draft: String
    let fontSize: CGFloat
    let renderSeed: String?
    let textColumnMaxWidth: CGFloat
    let mermaidHeight: CGFloat
    var frameworkName: String? = nil

    @State private var committedLength = 0
    @State private var segmentation: StreamingBlockSegmentation?

    var body: some View {
        let active = segmentation ?? StreamingBlockSegmenter.segment(
            draft: draft,
            previousCommittedLength: committedLength
        )

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if !active.committedText.isEmpty {
                QuickAssistStyledResponseView(
                    text: active.committedText,
                    fontSize: fontSize,
                    markdownRenderMode: .preserveWhitespace,
                    renderSeed: renderSeed,
                    textColumnMaxWidth: textColumnMaxWidth,
                    mermaidHeight: mermaidHeight,
                    mermaidActivation: .placeholder,
                    frameworkName: frameworkName
                )
            }

            HStack(alignment: .bottom, spacing: 0) {
                if !active.tailText.isEmpty {
                    Text(active.tailText)
                        .font(OverlayType.body(fontSize))
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                        .frame(maxWidth: textColumnMaxWidth, alignment: .leading)
                }
                StreamingCursorView(textRevision: draft.count, fontSize: fontSize)
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: draft) { _, newDraft in
            // Segment once per token here instead of once in body plus once
            // in onChange; body reads the stored result.
            let next = StreamingBlockSegmenter.segment(
                draft: newDraft,
                previousCommittedLength: committedLength
            )
            committedLength = next.committedLength
            segmentation = next
        }
        .onChange(of: renderSeed) { _, _ in
            committedLength = 0
            segmentation = nil
        }
    }
}
