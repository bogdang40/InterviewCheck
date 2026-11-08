import SwiftUI

/// Recent scores as a line over the two threshold lines.
struct LiveTestHistoryChart: View {
    let history: ScoreHistory
    let enterThreshold: Float
    let exitThreshold: Float
    var height: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            FieldLabel(text: "Score history")
            GeometryReader { geometry in
                ZStack {
                    thresholdLine(value: enterThreshold, tone: .success, size: geometry.size)
                    thresholdLine(value: exitThreshold, tone: .warning, size: geometry.size)
                    if history.scores.count > 1 {
                        scoreLine(size: geometry.size)
                            .stroke(OverlayPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: height)
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.sm)
        }
        .accessibilityLabel("Score history, \(history.scores.count) samples")
    }

    private func thresholdLine(value: Float, tone: OverlayTone, size: CGSize) -> some View {
        let y = size.height * CGFloat(1 - min(max(value, 0), 1))
        return Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(tone.color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func scoreLine(size: CGSize) -> Path {
        Path { path in
            let stepX = size.width / CGFloat(max(history.capacity - 1, 1))
            for (index, score) in history.scores.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height * CGFloat(1 - min(max(score, 0), 1))
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}
