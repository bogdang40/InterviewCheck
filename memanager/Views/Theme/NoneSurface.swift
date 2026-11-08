import SwiftUI

/// None uses a quiet reading surface without optical glass. The tiny grain
/// texture is generated once and stays fixed while content streams or scrolls.
struct NoneSurface: View {
    let opacity: Double
    var usesSolidFallback = false
    var cornerRadius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(OverlayPalette.backdropBase.opacity(fillOpacity))
            .overlay {
                if !usesSolidFallback, let grain = SurfaceGrain.image {
                    shape.fill(ImagePaint(image: grain, scale: 0.5))
                        .opacity(0.025)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fillOpacity: Double {
        guard !usesSolidFallback else { return 1 }
        let value = opacity.isFinite ? min(1, max(0.5, opacity)) : 0.75
        return 0.84 + (value - 0.5) * 0.16
    }
}
