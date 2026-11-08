import SwiftUI

/// A verification status as a dot in its semantic tone. The Kit's
/// `StatusDot` carries session states; this one carries a tone so the
/// same dot works in the strip, the navigator, and the thread list.
/// Kit candidate: StatusDot with an explicit tone.
struct QuickAssistVerificationDot: View {
    let status: QuickAssistVerificationStatus?
    var size: CGFloat = 8

    private var tone: OverlayTone {
        status?.tone ?? .neutral
    }

    var body: some View {
        Circle()
            .fill(tone == .neutral ? OverlayPalette.textTertiary : tone.color)
            .frame(width: size, height: size)
            .accessibilityLabel(status?.displayLabel ?? "Pending")
            .help(status?.displayLabel ?? "Pending")
    }
}
