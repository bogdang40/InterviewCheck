import SwiftUI

/// Renders a 1D array with an optional window overlay and pointer markers.
/// Cells are small overlay cards; highlighted cells take the accent tint,
/// the window is an accent stroked box that tweens between its bounds, and
/// pointers sit under the row in secondary text.
struct CanvasArraySceneView: View {
    let array: CanvasArrayPayload
    let window: CanvasWindowPayload?
    let pointers: [CanvasPointerPayload]
    let highlightedIndices: Set<Int>

    private let cellWidth: CGFloat = 44
    private let cellHeight: CGFloat = 44
    private let cellSpacing: CGFloat = 6

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let label = array.label, !label.isEmpty {
                FieldLabel(text: label)
            }
            ZStack(alignment: .topLeading) {
                if let window {
                    windowOverlay(window: window)
                }
                cellsRow
                pointerRow
            }
        }
    }

    private var cellsRow: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(array.values.enumerated()), id: \.offset) { index, value in
                cell(value: value, index: index)
            }
        }
    }

    private func cell(value: String, index: Int) -> some View {
        let highlighted = highlightedIndices.contains(index)
        return VStack(spacing: DesignTokens.Spacing.xxs) {
            Text(value)
                .font(OverlayType.mono)
                .foregroundStyle(OverlayPalette.textPrimary)
            Text("\(index)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .frame(width: cellWidth, height: cellHeight)
        .background(cellShape.fill(highlighted ? OverlayPalette.accentTint : .clear))
        .overlayCard(
            highlighted ? .raised : .base,
            cornerRadius: DesignTokens.Radius.sm,
            stroke: highlighted ? OverlayPalette.accentStroke : nil
        )
        .animation(DesignTokens.Motion.focus, value: highlighted)
    }

    private func windowOverlay(window: CanvasWindowPayload) -> some View {
        let leftPosition = xPosition(for: window.left)
        let rightPosition = xPosition(for: window.right) + cellWidth
        let width = max(0, rightPosition - leftPosition)
        return cellShape
            .fill(OverlayPalette.accentTint)
            .overlay(cellShape.stroke(OverlayPalette.accentStroke, lineWidth: 1.5))
            .frame(width: width, height: cellHeight + 6)
            .offset(x: leftPosition, y: -3)
            .animation(DesignTokens.Motion.sectionExpand, value: window)
    }

    private var pointerRow: some View {
        ForEach(pointers, id: \.id) { pointer in
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(OverlayType.micro)
                Text(pointer.name)
                    .font(OverlayType.monoMicro)
            }
            .foregroundStyle(OverlayPalette.textSecondary)
            .frame(width: cellWidth)
            .offset(x: xPosition(for: pointer.index), y: cellHeight + 4)
            .animation(DesignTokens.Motion.turnSwap, value: pointer.index)
        }
    }

    private func xPosition(for index: Int) -> CGFloat {
        CGFloat(index) * (cellWidth + cellSpacing)
    }
}
