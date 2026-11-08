import SwiftUI

/// A persistent texture above the native blur. The material controls blur and
/// tint; this view supplies the same fine grain in every window activity state.
struct OverlayReadingSurface: View {
    let style: BorderShaderStyle
    let opacity: Double
    var usesSolidFallback = false
    var cornerRadius: CGFloat = 26

    var body: some View {
        Group {
            if style == .none || usesSolidFallback {
                NoneSurface(opacity: opacity, usesSolidFallback: usesSolidFallback,
                            cornerRadius: cornerRadius)
            } else if let grain = SurfaceGrain.image {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ImagePaint(image: grain, scale: 0.5))
                    .opacity(0.035)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
