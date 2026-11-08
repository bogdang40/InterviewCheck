import SwiftUI

/// Ring that fills as enrollment collects enough speech, with the percent
/// in the middle. Progress is 0 to 100.
struct EnrollmentProgressRing: View {
    let progress: Float
    var diameter: CGFloat = 130
    var lineWidth: CGFloat = 10

    private var fraction: CGFloat {
        CGFloat(min(max(progress / 100, 0), 1))
    }

    private var color: Color {
        progress >= 100 ? OverlayTone.success.color : OverlayPalette.accent
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(OverlayPalette.hairlineStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DesignTokens.Motion.sectionExpand, value: progress)
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text("\(Int(progress))%")
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .monospacedDigit()
                Text("Progress")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Enrollment progress \(Int(progress)) percent")
    }
}
