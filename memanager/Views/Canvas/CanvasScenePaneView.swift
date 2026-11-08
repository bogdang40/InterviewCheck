import SwiftUI

/// Switches between the supported canvas scene types for a given
/// `CanvasScene`. MVP renders only array scenes; grid, graph, and system
/// design scenes are month one scope. The shell mounts this pane at a
/// fixed height, so it owns its own scroll.
struct CanvasScenePaneView: View {
    let scene: CanvasScene

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                ForEach(arrays, id: \.id) { array in
                    CanvasArraySceneView(
                        array: array,
                        window: scene.windows[array.id],
                        pointers: scene.pointers.values.filter { $0.targetID == array.id },
                        highlightedIndices: indicesHighlighted(for: array.id)
                    )
                }
                if scene.arrays.isEmpty {
                    emptyState
                }
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .overlayCard(.base)
    }

    private var arrays: [CanvasArrayPayload] {
        scene.arrays.values.sorted { $0.id < $1.id }
    }

    private var emptyState: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.textTertiary)
            Text("Waiting for a scene")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
            Spacer(minLength: 0)
        }
    }

    private func indicesHighlighted(for sceneID: String) -> Set<Int> {
        var indices: Set<Int> = []
        for highlight in scene.highlights where highlight.targetID == sceneID && highlight.kind == .indices {
            for part in highlight.value.split(separator: ",") {
                if let index = Int(part.trimmingCharacters(in: .whitespaces)) {
                    indices.insert(index)
                }
            }
        }
        return indices
    }
}
