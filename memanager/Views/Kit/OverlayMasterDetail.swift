import SwiftUI

/// Which pane a two column screen shows when the overlay is too narrow to
/// show both side by side.
enum MasterDetailPane: Hashable {
    case list
    case detail
}

/// Pure sizing rules for the two column overlay screens.
enum MasterDetailLayoutResolver {
    /// Below this width each task gets a complete reading column.
    static let splitMinimumWidth: CGFloat = 900

    static func isSplit(width: CGFloat) -> Bool {
        width >= splitMinimumWidth
    }

    static func listWidth(for width: CGFloat) -> CGFloat {
        OverlayColumnWidth.list(for: width)
    }

    /// The pane to show after the user picks a row: picking a row means
    /// they want the detail whenever only one pane is visible.
    static func pane(afterSelectionIn width: CGFloat, current: MasterDetailPane) -> MasterDetailPane {
        isSplit(width: width) ? current : .detail
    }
}

/// Master detail scaffold shared by Workspaces and Knowledge: a readable
/// list column beside the detail from the regular breakpoint up, and a
/// segment strip that swaps between the two below it.
struct OverlayMasterDetail<ListContent: View, DetailContent: View>: View {
    let width: CGFloat
    @Binding var pane: MasterDetailPane
    var listTitle: String = "List"
    var detailTitle: String = "Detail"
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent

    private var segments: [SegmentItem<MasterDetailPane>] {
        [
            SegmentItem(id: .list, title: listTitle, systemImage: "list.bullet"),
            SegmentItem(id: .detail, title: detailTitle, systemImage: "doc.text")
        ]
    }

    var body: some View {
        let split = MasterDetailLayoutResolver.isSplit(width: width)
        let listWidth = split ? MasterDetailLayoutResolver.listWidth(for: width) : width
        let detailWidth = split ? max(0, width - listWidth - 1) : width
        let showsList = split || pane == .list
        let showsDetail = split || pane == .detail
        VStack(spacing: 0) {
            if !split {
                SegmentStrip(items: segments, selection: $pane)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                Hairline()
            }
            // Keep both panes mounted so going back to the list does not
            // discard an editor, document shelf or scroll position.
            HStack(spacing: 0) {
                list()
                    .frame(width: listWidth)
                    .frame(width: showsList ? listWidth : 0)
                    .clipped()
                    .opacity(showsList ? 1 : 0)
                    .allowsHitTesting(showsList)
                    .disabled(!showsList)
                    .accessibilityHidden(!showsList)
                if split { Hairline(axis: .vertical) }
                detail()
                    .frame(width: detailWidth)
                    .frame(width: showsDetail ? detailWidth : 0)
                    .clipped()
                    .opacity(showsDetail ? 1 : 0)
                    .allowsHitTesting(showsDetail)
                    .disabled(!showsDetail)
                    .accessibilityHidden(!showsDetail)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
