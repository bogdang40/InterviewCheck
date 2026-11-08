import SwiftUI

/// Detail column of the two column History layout: the pane strip on top
/// and the active pane below, or an invitation to pick a session.
struct SessionHistoryRightPane<Content: View>: View {
    let panes: [HistoryPane]
    @Binding var activePane: HistoryPane
    let hasSelection: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HistoryPaneStrip(panes: panes, selection: $activePane)
            Hairline()
            if hasSelection {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HistorySelectionEmptyState()
            }
        }
    }
}
