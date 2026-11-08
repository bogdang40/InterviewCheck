import AppKit
import SwiftUI

/// SwiftUI previews use one material. The live panel owns its AppKit glass host.
struct PearlGlassModifier: ViewModifier {
    var opacity: Double = 0.95
    var radius: CGFloat = 26
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(shape.fill(OverlayPalette.backdropBase))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.clear.tint(OverlayPalette.backdropBase
                    .opacity(0.12 + min(1, max(0, opacity)) * 0.08)), in: shape)
        } else {
            content.background {
                PearlWindowMaterial()
                    .opacity(min(1, max(0, opacity)))
                    .clipShape(shape)
            }
        }
    }
}

/// Controls on glass use a selected fill, without another glass sampling layer.
struct PearlControlPlate: View {
    var radius: CGFloat = 12
    var tint: Color = OverlayPalette.accentTint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        shape.fill(tint.opacity(reduceTransparency || contrast == .increased ? 1 : 0.7))
            .overlay(shape.strokeBorder(OverlayPalette.glassHighlight.opacity(0.35), lineWidth: 1))
    }
}

private struct PearlWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    func pearlGlass(opacity: Double = 0.95, radius: CGFloat = 26) -> some View {
        modifier(PearlGlassModifier(opacity: opacity, radius: radius))
    }
}
