import SwiftUI

/// Minimal line chart for a series of values: a hairline midline track,
/// the series in a tone color, and a dot on the latest value.
struct SparklineView: View {
    let values: [Double]
    var tone: OverlayTone = .neutral
    var height: CGFloat = 24
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let points = SparklineGeometry.points(for: values, in: proxy.size)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                }
                .stroke(OverlayPalette.hairlineStrong, lineWidth: 1)
                if points.count > 1 {
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    Circle()
                        .fill(lineColor)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var lineColor: Color {
        tone == .neutral ? OverlayPalette.textSecondary : tone.color
    }
}

/// Pure point mapping for the sparkline so the scaling can be tested.
enum SparklineGeometry {
    static func normalized(_ values: [Double]) -> [Double] {
        guard let minValue = values.min(), let maxValue = values.max() else { return [] }
        let range = maxValue - minValue
        guard range > 0 else { return values.map { _ in 0.5 } }
        return values.map { ($0 - minValue) / range }
    }

    static func points(for values: [Double], in size: CGSize, inset: CGFloat = 3) -> [CGPoint] {
        let normalized = normalized(values)
        guard !normalized.isEmpty else { return [] }
        let usableHeight = max(size.height - inset * 2, 0)
        guard normalized.count > 1 else {
            return [CGPoint(x: size.width, y: inset + usableHeight * 0.5)]
        }
        let stepX = size.width / CGFloat(normalized.count - 1)
        return normalized.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * stepX, y: inset + usableHeight * (1 - CGFloat(value)))
        }
    }
}
