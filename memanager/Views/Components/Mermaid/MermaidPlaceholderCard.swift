import SwiftUI

/// Lightweight stand in for a mermaid diagram during streaming: fixed
/// height, no WKWebView. Real diagrams boot at settle, staggered through
/// the render scheduler, instead of storming all at once when the stream
/// ends.
struct MermaidPlaceholderCard: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "flowchart")
                .font(OverlayType.display)
                .foregroundStyle(OverlayPalette.textTertiary)
            Text("Diagram renders when the response completes")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)
    }
}
