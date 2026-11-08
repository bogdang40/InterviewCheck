import SwiftUI

/// Only the decorative animation is removed when hidden. Its surrounding
/// editor, screen and model retain their identities and state.
struct OverlayAmbientAnimation<Content: View>: View {
    var isEnabled = true
    let animation: Animation
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.overlayContentIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isEnabled && isVisible && !reduceMotion {
            RepeatingContent(animation: animation, content: content)
        } else {
            content(false)
        }
    }
}

private struct RepeatingContent<Content: View>: View {
    let animation: Animation
    let content: (Bool) -> Content
    @State private var phase = false

    var body: some View {
        content(phase)
            .onAppear {
                withAnimation(animation) { phase = true }
            }
    }
}
