import SwiftUI

/// The launch toast: one line saying the app is ready and the key that
/// shows the overlay. Drawn on the palette's canvas with a hairline, no
/// material, matching the main window.
struct StartupIndicatorView: View {
    @State private var opacity: Double = 0

    static let size = CGSize(width: 220, height: 92)

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OverlayLayout.panelCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(OverlayType.title)
                    .foregroundStyle(OverlayTone.success.color)
                Text("\(AppBrand.name) ready")
                    .font(OverlayType.title)
                    .foregroundStyle(OverlayPalette.textPrimary)
            }
            KeyHint(label: "Show or hide", shortcut: ShortcutCatalog.toggleOverlay)
        }
        .padding(.horizontal, DesignTokens.Spacing.xxl)
        .padding(.vertical, DesignTokens.Spacing.lg)
        .background(shape.fill(OverlayPalette.canvas.opacity(0.92)))
        .overlay(shape.stroke(OverlayPalette.hairlineStrong, lineWidth: 1))
        .opacity(opacity)
        .onAppear {
            withAnimation(DesignTokens.Motion.panelDisclosure) {
                opacity = 1
            }
        }
        .accessibilityLabel("\(AppBrand.name) ready. \(ShortcutCatalog.toggleOverlay) shows or hides the overlay.")
    }
}
