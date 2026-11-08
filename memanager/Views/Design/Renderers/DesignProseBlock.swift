import SwiftUI

/// The prose a section carries before its first step, as speakable chunks.
/// Renders nothing when the text is blank so a card never shows an empty gap.
struct DesignProseBlock: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        if DesignTextValidator.isMeaningful(text) {
            SpeakableMarkdownView(
                text: text,
                fontSize: fontSize,
                showChunkIndicators: false,
                chunkTrackingMode: .teleprompter
            )
        }
    }
}
