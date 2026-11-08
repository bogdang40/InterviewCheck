import SwiftUI

/// What the user is about to delete.
enum SidebarDeleteAction {
    case thread(QuickAssistThreadSummary)
    case allThreads(count: Int)
    case threads([QuickAssistThreadSummary])

    var title: String {
        switch self {
        case .thread: return "Delete this thread?"
        case .allThreads: return "Delete all threads?"
        case .threads(let threads):
            return threads.count == 1 ? "Delete selected thread?" : "Delete \(threads.count) selected threads?"
        }
    }

    var message: String {
        switch self {
        case .thread(let summary):
            return "\"\(summary.title)\" and all of its turns will be removed for good."
        case .threads(let threads):
            if threads.count == 1 {
                return "The selected thread and all its turns will be permanently deleted. Other threads will be kept."
            }
            return "The \(threads.count) selected threads and all their turns will be permanently deleted. Other threads will be kept."
        case .allThreads(let count):
            let label = count == 1 ? "thread" : "threads"
            return "All \(count) Quick Assist \(label) and their turns will be removed for good."
        }
    }
}

/// Inline confirmation for a delete, rendered as a critical banner at the
/// top of the list so nothing modal covers the drawer.
struct SidebarDeleteConfirmationBanner: View {
    let action: SidebarDeleteAction
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ToneBanner(
            tone: .critical,
            title: action.title,
            message: action.message,
            systemImage: "trash",
            actions: [
                BannerAction(title: "Delete", kind: .destructive, action: onConfirm),
                BannerAction(title: "Cancel", kind: .ghost, action: onCancel)
            ],
            onDismiss: onCancel
        )
    }
}
