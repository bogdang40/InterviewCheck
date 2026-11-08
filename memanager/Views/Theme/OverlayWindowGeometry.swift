import CoreGraphics

/// The content rectangle owns placement. Its optional border expands the
/// backing window and may extend beyond the display without reducing content.
enum OverlayWindowGeometry {
    enum AnchorEdge { case left, right }

    static func contentFrame(_ requested: CGRect, in screenVisibleFrame: CGRect,
                             edge: AnchorEdge) -> CGRect {
        let available = screenVisibleFrame.insetBy(dx: OverlayLayout.desktopHorizontalInset, dy: 0)
        let requestedWidth = requested.width.isFinite ? requested.width : 400
        let width = min(max(400, requestedWidth), available.width)
        let x = edge == .left ? available.minX : available.maxX - width
        return CGRect(x: x, y: available.minY, width: width, height: available.height)
    }

    static func windowFrame(around contentFrame: CGRect, borderWidth: CGFloat) -> CGRect {
        let outset = borderWidth.isFinite ? max(0, borderWidth) : 0
        return contentFrame.insetBy(dx: -outset, dy: -outset)
    }
}
