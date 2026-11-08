import CoreGraphics

/// Layout constants and breakpoints shared by the shell and every surface.
/// The overlay is a column anchored to a screen edge, resizable from 400
/// points, so layouts adapt to width, never to height.
enum OverlayLayout {

    enum Breakpoint: Equatable, Comparable {
        case compact
        case regular
        case wide
    }

    static let compactMaximumWidth: CGFloat = 560
    static let wideMinimumWidth: CGFloat = 900

    static func breakpoint(for width: CGFloat) -> Breakpoint {
        if width < compactMaximumWidth { return .compact }
        if width < wideMinimumWidth { return .regular }
        return .wide
    }

    // MARK: Shell bands

    static let commandBarHeight: CGFloat = 58
    static let liveStripHeight: CGFloat = 30
    static let statusBarHeight: CGFloat = 26

    // MARK: Drawer

    static let drawerWidth: CGFloat = 250
    static let drawerMinimumContentWidth: CGFloat = 420

    /// Whether the drawer can sit beside the stage without starving it.
    static func drawerFits(in width: CGFloat) -> Bool {
        width >= wideMinimumWidth && width - drawerWidth >= drawerMinimumContentWidth
    }

    // MARK: Insets

    static let stageInset: CGFloat = 20
    static let readingColumnMaximum: CGFloat = 880
    static let panelCornerRadius: CGFloat = 36
    static let glassPerimeterInset = CGFloat(BorderShaderConfiguration.defaultWidth)
    static let desktopHorizontalInset: CGFloat = 12

    /// Width of the text column inside a stage, so long lines stay readable.
    static func readingWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth - 2 * stageInset, 320), readingColumnMaximum)
    }
}
