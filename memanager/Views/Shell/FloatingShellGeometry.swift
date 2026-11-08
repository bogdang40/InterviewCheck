import CoreGraphics

/// Shared content bounds for SwiftUI and the native glass backdrop.
/// Coordinates start at the top left. Each native rim expands outwards.
struct FloatingShellGeometry: Equatable {
    static let railMinimumWidth: CGFloat = 760
    static let railWidth: CGFloat = 160
    static let edgeSpacing: CGFloat = 12

    let navigation: CGRect
    let content: CGRect
    let dock: CGRect
    let workspace: CGRect
    let isCompact: Bool
    let borderWidth: CGFloat
    let dockGap: CGFloat

    init(size: CGSize, borderWidth requestedBorderWidth: CGFloat) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        borderWidth = requestedBorderWidth.isFinite ? min(48, max(0, requestedBorderWidth)) : 0
        isCompact = width - 2 * borderWidth < Self.railMinimumWidth
        let outer = min(Self.edgeSpacing + borderWidth, min(width, height) / 2)
        let contentX = isCompact ? outer : outer + Self.railWidth + 20 + 2 * borderWidth
        let contentWidth = max(0, width - outer - contentX)
        let availableHeight = max(0, height - 2 * outer)
        let desiredNavigationHeight: CGFloat = isCompact ? 44 : 0
        let desiredNavigationGap: CGFloat = isCompact ? 16 + 2 * borderWidth : 0
        let desiredDockHeight: CGFloat = isCompact || contentWidth < 450 ? 88 : 64
        let desiredDockGap = 18 + 2 * borderWidth
        // Small transient window proposals shrink the bands together rather
        // than produce negative frames or put interactive controls offscreen.
        let scale = min(1, availableHeight / (desiredNavigationHeight + desiredNavigationGap
            + desiredDockHeight + desiredDockGap + 160))
        let navigationHeight = desiredNavigationHeight * scale
        let navigationGap = desiredNavigationGap * scale
        let dockHeight = desiredDockHeight * scale
        dockGap = desiredDockGap * scale
        let contentY = outer + navigationHeight + navigationGap
        let contentHeight = max(0, availableHeight - navigationHeight - navigationGap - dockHeight - dockGap)
        content = CGRect(x: contentX, y: contentY, width: contentWidth, height: contentHeight)
        dock = CGRect(x: contentX, y: content.maxY + dockGap,
                      width: contentWidth, height: dockHeight)
        workspace = CGRect(x: contentX, y: contentY, width: contentWidth,
                           height: contentHeight + dockGap + dockHeight)
        navigation = CGRect(x: outer, y: outer,
                            width: isCompact ? max(0, width - 2 * outer) : Self.railWidth,
                            height: isCompact ? navigationHeight : contentHeight)
    }

    /// The welcome animation and the navigation brand reserve this same slot.
    var brandCenter: CGPoint {
        CGPoint(x: navigation.minX + 28, y: navigation.minY + (isCompact ? 22 : 36))
    }
}
