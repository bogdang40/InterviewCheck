import SwiftUI

/// Circular numbered badge for ordered cards. Active fills with the given
/// color; otherwise the number sits in a tinted ring of the same color.
struct NumberBadge: View {
    let number: Int
    var color: Color = OverlayPalette.accent
    var isActive: Bool = false
    var size: CGFloat = 26

    var body: some View {
        Text("\(number)")
            .font(OverlayType.captionStrong)
            .monospacedDigit()
            .foregroundStyle(isActive ? OverlayPalette.onAccent : color)
            .frame(width: size, height: size)
            .background(Circle().fill(isActive ? color.opacity(0.9) : color.opacity(0.14)))
            .overlay(Circle().stroke(isActive ? .clear : color.opacity(0.36), lineWidth: 1))
            .accessibilityLabel("Number \(number)")
    }
}
