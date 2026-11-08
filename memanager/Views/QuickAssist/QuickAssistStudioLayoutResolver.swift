import CoreGraphics

/// Width driven layout decisions for the studio. Height never matters: the
/// stage owns the scroll and the dock takes its natural height.
struct QuickAssistStudioLayoutPlan: Equatable {
    let breakpoint: OverlayLayout.Breakpoint
    /// Compact widths stack the header into two rows.
    let headerWrapsToTwoRows: Bool
    /// Compact widths shrink the secondary toolbar actions to icons.
    let toolbarUsesIconActions: Bool
    /// The mode menu shows the resolved mode caption only where it fits.
    let showsResolvedModeCaption: Bool
    /// The reading column for the answer.
    let readingWidth: CGFloat
}

enum QuickAssistStudioLayoutResolver {
    static func resolve(availableWidth: CGFloat) -> QuickAssistStudioLayoutPlan {
        let breakpoint = OverlayLayout.breakpoint(for: availableWidth)
        return QuickAssistStudioLayoutPlan(
            breakpoint: breakpoint,
            headerWrapsToTwoRows: breakpoint == .compact,
            toolbarUsesIconActions: breakpoint == .compact,
            showsResolvedModeCaption: breakpoint == .wide,
            readingWidth: OverlayLayout.readingWidth(for: availableWidth)
        )
    }
}
