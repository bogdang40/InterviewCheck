import SwiftUI

/// Speakable chunks with fenced code support: prose segments become chunk
/// views and fenced segments go through the fenced block renderer.
struct SpeakableMarkdownView: View {
    let text: String
    let fontSize: CGFloat
    let showChunkIndicators: Bool
    let chunkTrackingMode: ChunkTrackingMode

    init(
        text: String,
        fontSize: CGFloat = 14,
        showChunkIndicators: Bool = true,
        chunkTrackingMode: ChunkTrackingMode = .teleprompter
    ) {
        self.text = text
        self.fontSize = fontSize
        self.showChunkIndicators = showChunkIndicators
        self.chunkTrackingMode = chunkTrackingMode
    }

    private var segments: [FencedMarkdownSegment] {
        FencedMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .text(let value):
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SpeakableChunksView(
                            text: value,
                            fontSize: fontSize,
                            showChunkIndicators: showChunkIndicators,
                            chunkTrackingMode: chunkTrackingMode
                        )
                    }
                case .code(let languageHint, let code):
                    FencedMarkdownBlockView(
                        languageHint: languageHint,
                        code: code,
                        fontSize: fontSize
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
