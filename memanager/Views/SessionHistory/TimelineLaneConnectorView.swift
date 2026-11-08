import SwiftUI

/// The spine segment beside a node: a hairline through the row with a
/// severity dot at its centre. The line stops at the first and last rows.
struct TimelineLaneConnectorView: View {
    let tone: OverlayTone
    let isFirst: Bool
    let isLast: Bool

    static let width: CGFloat = 20
    private let dotDiameter: CGFloat = 8

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let midX = geometry.size.width / 2
                let midY = geometry.size.height / 2
                Path { path in
                    path.move(to: CGPoint(x: midX, y: isFirst ? midY : 0))
                    path.addLine(to: CGPoint(x: midX, y: isLast ? midY : geometry.size.height))
                }
                .stroke(OverlayPalette.hairlineStrong, lineWidth: 1.5)
            }
            Circle()
                .fill(tone.color)
                .frame(width: dotDiameter, height: dotDiameter)
                .overlay(Circle().stroke(OverlayPalette.canvas, lineWidth: 1.5))
        }
        .frame(width: Self.width)
    }
}

/// Timestamp column shared by single nodes and clusters.
struct TimelineTimestampLabel: View {
    let date: Date

    static let width: CGFloat = 56

    var body: some View {
        Text(TimelineTimeFormatter.clock(date))
            .font(OverlayType.monoMicro)
            .foregroundStyle(OverlayPalette.textTertiary)
            .frame(width: Self.width, alignment: .trailing)
            .padding(.top, DesignTokens.Spacing.sm)
    }
}
