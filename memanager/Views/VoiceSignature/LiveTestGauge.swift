import SwiftUI

/// Half circle gauge for the smoothed recognition score with the two
/// thresholds marked on the arc.
struct LiveTestGauge: View {
    let score: Float
    let enterThreshold: Float
    let exitThreshold: Float
    var diameter: CGFloat = 180
    var lineWidth: CGFloat = 12

    private var tone: OverlayTone {
        LiveTestScoreTone.tone(score: score, enter: enterThreshold, exit: exitThreshold)
    }

    private var radius: CGFloat { diameter / 2 }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: LiveTestGaugeGeometry.arcStart, to: LiveTestGaugeGeometry.arcStart + LiveTestGaugeGeometry.arcLength)
                .stroke(OverlayPalette.hairlineStrong, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: LiveTestGaugeGeometry.arcStart, to: LiveTestGaugeGeometry.arcEnd(for: score))
                .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(90))
                .animation(DesignTokens.Motion.focus, value: score)

            marker(value: enterThreshold, tone: .success)
            marker(value: exitThreshold, tone: .warning)

            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text(String(format: "%.2f", score))
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .monospacedDigit()
                Text("Similarity")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .offset(y: -DesignTokens.Spacing.md)
        }
        .frame(width: diameter, height: diameter)
        // Keep the rounded stroke inside the half-circle's clipping bounds.
        .padding(lineWidth / 2)
        .frame(height: radius + lineWidth, alignment: .top)
        .clipped()
        .accessibilityLabel(String(format: "Voice similarity %.2f", score))
    }

    private func marker(value: Float, tone: OverlayTone) -> some View {
        let offset = LiveTestGaugeGeometry.markerOffset(value: value, radius: radius)
        return Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(OverlayPalette.canvas, lineWidth: 1))
            .offset(x: offset.x, y: offset.y)
    }
}

/// Legend naming the two threshold markers.
struct LiveTestThresholdLegend: View {
    let enterThreshold: Float
    let exitThreshold: Float

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            legend("Enter", value: enterThreshold, tone: .success)
            legend("Exit", value: exitThreshold, tone: .warning)
        }
    }

    private func legend(_ title: String, value: Float, tone: OverlayTone) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Text(String(format: "%@ %.2f", title, value))
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .monospacedDigit()
        }
    }
}
