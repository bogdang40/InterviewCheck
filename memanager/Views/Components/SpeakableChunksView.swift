import SwiftUI

enum ChunkTrackingMode: Equatable {
    case none
    case teleprompter
}

/// Narration as short chunks. A retained, inactive surface keeps its local
/// cursor without writing the visible surface's shared teleprompter state.
struct SpeakableChunksView: View {
    let text: String
    let fontSize: CGFloat
    let showChunkIndicators: Bool
    let chunkTrackingMode: ChunkTrackingMode
    let chunkCountReportingEnabled: Bool

    @ObservedObject private var controller = SessionController.shared
    @Environment(\.isEnabled) private var isEnabled
    @State private var savedChunkIndex = 0

    init(
        text: String,
        fontSize: CGFloat = 14,
        showChunkIndicators: Bool = true,
        chunkTrackingMode: ChunkTrackingMode = .teleprompter,
        chunkCountReportingEnabled: Bool = true
    ) {
        self.text = text
        self.fontSize = fontSize
        self.showChunkIndicators = showChunkIndicators
        self.chunkTrackingMode = chunkTrackingMode
        self.chunkCountReportingEnabled = chunkCountReportingEnabled
    }

    private var chunks: [SpeakableChunk] {
        SpeakableChunkSplitter.chunks(from: text)
    }

    private var reportsChunkCount: Bool {
        isEnabled && chunkTrackingMode == .teleprompter && chunkCountReportingEnabled
    }

    var body: some View {
        let chunkList = chunks
        Group {
            if chunkList.isEmpty {
                Text(text)
                    .font(OverlayType.body(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(Array(chunkList.enumerated()), id: \.element.id) { index, chunk in
                        SpeakableChunkRow(
                            chunk: chunk,
                            fontSize: fontSize,
                            showsIndicator: showChunkIndicators && chunkList.count > 1,
                            state: SpeakableChunkReadingState.resolve(
                                index: index,
                                teleprompterEnabled: controller.teleprompterModeEnabled,
                                currentIndex: reportsChunkCount ? controller.currentChunkIndex : savedChunkIndex
                            )
                        )
                    }
                }
            }
        }
        .onAppear { restoreCursor(chunkCount: chunkList.count) }
        .onChange(of: text) { _, _ in
            savedChunkIndex = 0
            guard reportsChunkCount else { return }
            controller.setChunkCount(chunkList.count)
            controller.resetChunkNavigation()
        }
        .onChange(of: reportsChunkCount) { _, active in
            guard active else { return }
            restoreCursor(chunkCount: chunkList.count)
        }
        .onChange(of: controller.currentChunkIndex) { _, index in
            guard reportsChunkCount else { return }
            savedChunkIndex = index
        }
    }

    private func restoreCursor(chunkCount: Int) {
        guard reportsChunkCount else { return }
        let restored = min(savedChunkIndex, max(0, chunkCount - 1))
        controller.setChunkCount(chunkCount)
        controller.currentChunkIndex = restored
    }
}
