import SwiftUI

/// List row with hover and selection states. Content is free form so
/// sessions, threads, workspaces, and facts can all share one row chrome.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    var accentEdge: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(shape.fill(fill))
                .overlay(shape.stroke(isSelected ? OverlayPalette.accentStroke : .clear, lineWidth: 1))
                .overlay(alignment: .leading) {
                    if accentEdge {
                        Capsule()
                            .fill(OverlayPalette.accent.opacity(isSelected ? 0.9 : 0.35))
                            .frame(width: 3)
                            .padding(.vertical, 8)
                            .padding(.leading, 2)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(DesignTokens.Motion.focus, value: isHovering)
    }

    private var fill: Color {
        if isSelected { return OverlayPalette.accentTint }
        if isHovering { return OverlayPalette.surfaceRaised }
        return .clear
    }
}
