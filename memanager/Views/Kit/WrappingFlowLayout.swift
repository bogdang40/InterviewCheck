import SwiftUI

/// Lays children out left to right and wraps to a new row when the next
/// one would not fit. A child wider than the row is offered the row width
/// so text inside it wraps instead of overflowing the overlay.
struct WrappingFlowLayout: Layout {
    var spacing: CGFloat = DesignTokens.Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: rowWidth(for: proposal), subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(in: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func rowWidth(for proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width > 0 else { return .infinity }
        return width
    }

    private func arrange(in rowWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if rowWidth.isFinite, size.width > rowWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: rowWidth, height: nil))
            }
            if x > 0, x + size.width > rowWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }

        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}
