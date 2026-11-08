import SwiftUI

/// Pre first token latency mask: ghost rows shaped like the incoming answer
/// (opener card, beat heading, talking points) with a soft breathing pulse.
/// Collapses to static rows when the user prefers reduced motion.
struct QuickAssistLoadingSkeleton: View {
    let fontSize: CGFloat

    @Environment(\.overlayContentIsVisible) private var isContentVisible

    var body: some View {
        OverlayAmbientAnimation(animation: .easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase in
            skeleton.opacity(phase ? 0.55 : 1)
        }
        .accessibilityLabel("Generating answer")
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if isContentVisible {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "hourglass")
                        .accessibilityLabel("Loading")
                }
                Text("Gathering evidence")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }

            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(OverlayPalette.accentTint)
                .frame(maxWidth: 460)
                .frame(height: fontSize * 3.4)

            beat(headingFraction: 0.34, lines: [0.92, 0.86, 0.64])
            beat(headingFraction: 0.28, lines: [0.88, 0.52])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beat(headingFraction: CGFloat, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            line(widthFraction: headingFraction, height: fontSize + 2)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, fraction in
                line(widthFraction: fraction, height: fontSize * 0.9)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
    }

    private func line(widthFraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                .fill(OverlayPalette.surfaceOverlay)
                .frame(width: proxy.size.width * widthFraction)
        }
        .frame(height: height)
    }
}
