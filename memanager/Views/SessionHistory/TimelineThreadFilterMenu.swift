import SwiftUI

/// Compact thread filter for the timeline: every thread available for the
/// session, or all of them.
struct TimelineThreadFilterMenu: View {
    @Binding var selectedThreadId: String?
    let threads: [QuickAssistThreadSummary]

    private var title: String {
        guard let selectedThreadId,
              let thread = threads.first(where: { $0.id == selectedThreadId }) else {
            return "All threads"
        }
        return String(thread.title.prefix(24))
    }

    var body: some View {
        OverlayMenuButton(title: title, systemImage: "bubble.left.and.bubble.right") {
            Button("All threads") {
                selectedThreadId = nil
                SessionController.shared.clearWorkstreamTimelineThreadFilter()
            }
            if !threads.isEmpty {
                Divider()
            }
            ForEach(threads) { thread in
                Button {
                    selectedThreadId = thread.id
                } label: {
                    if thread.id == selectedThreadId {
                        Label(thread.title, systemImage: "checkmark")
                    } else {
                        Text(thread.title)
                    }
                }
            }
        }
    }
}
