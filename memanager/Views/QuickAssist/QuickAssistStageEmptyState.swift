import SwiftUI

/// The stage before the first turn: what Generate does, where to type, and
/// the key for the deep tier.
struct QuickAssistStageEmptyState: View {
    let onGenerate: () -> Void
    let onFocusQuestion: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                emptyState.frame(minHeight: geometry.size.height)
            }
        }
    }

    private var emptyState: some View {
        OverlayEmptyState(
            systemImage: "text.bubble",
            title: "Ready to answer",
            message: "Generate answers the last question on the call with the transcript, your screen, and pinned memory alongside. Focus the question field to ask something specific.",
            primary: EmptyStateAction(title: "Generate", shortcut: ShortcutCatalog.quickAssist, action: onGenerate),
            secondary: EmptyStateAction(title: "Focus question", shortcut: ShortcutCatalog.quickAssistFocusQuestion, action: onFocusQuestion),
            hints: [("Deep tier", ShortcutCatalog.quickAssistDeep)],
            pulses: true
        )
    }
}
