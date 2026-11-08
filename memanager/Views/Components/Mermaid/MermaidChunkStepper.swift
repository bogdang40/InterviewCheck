import SwiftUI

/// Steps through the chunks of a diagram too large to read at once: the
/// chunk title, its position, and small previous and next buttons.
struct MermaidChunkStepper: View {
    let chunks: [MermaidDiagramChunker.Chunk]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    private var hasPrevious: Bool { selectedIndex > 0 }
    private var hasNext: Bool { selectedIndex + 1 < chunks.count }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Previous") {
                guard hasPrevious else { return }
                onSelect(selectedIndex - 1)
            }
            .buttonStyle(.overlay(.secondary, size: .small))
            .disabled(!hasPrevious)

            if chunks.indices.contains(selectedIndex) {
                Text(chunks[selectedIndex].title)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text("\(selectedIndex + 1)/\(chunks.count)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)

            Button("Next") {
                guard hasNext else { return }
                onSelect(selectedIndex + 1)
            }
            .buttonStyle(.overlay(.secondary, size: .small))
            .disabled(!hasNext)
        }
    }
}
