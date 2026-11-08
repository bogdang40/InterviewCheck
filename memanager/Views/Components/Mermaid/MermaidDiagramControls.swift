import SwiftUI

/// The diagram toolbar: a quiet title, zoom out, the current percent (tap
/// to reset), zoom in, and fullscreen. All icon buttons share the overlay
/// icon style so they read as one control group.
struct MermaidDiagramControls: View {
    @Binding var zoomScale: CGFloat
    var showsFullscreenControl: Bool = true
    let onFullscreen: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Diagram")
                .font(OverlayType.captionStrong)
                .foregroundStyle(OverlayPalette.textTertiary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button {
                setZoom(MermaidZoomPolicy.zoomedOut(zoomScale))
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.overlayIcon(size: 24))
            .disabled(!MermaidZoomPolicy.canZoomOut(zoomScale))
            .help("Zoom out")

            Button {
                zoomScale = MermaidZoomPolicy.reset
                SessionLogger.shared.logMermaidEvent(name: "adaptive_zoom_reset", details: "zoom=100")
            } label: {
                Text(MermaidZoomPolicy.percentLabel(zoomScale))
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .buttonStyle(.overlay(.ghost, size: .small))
            .help("Reset zoom")

            Button {
                setZoom(MermaidZoomPolicy.zoomedIn(zoomScale))
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.overlayIcon(size: 24))
            .disabled(!MermaidZoomPolicy.canZoomIn(zoomScale))
            .help("Zoom in")

            if showsFullscreenControl {
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.overlayIcon(size: 24))
                .help("Fullscreen")
            }
        }
    }

    private func setZoom(_ next: CGFloat) {
        zoomScale = next
        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_zoom_changed",
            details: "zoom=\(MermaidZoomPolicy.percent(next))"
        )
    }
}
