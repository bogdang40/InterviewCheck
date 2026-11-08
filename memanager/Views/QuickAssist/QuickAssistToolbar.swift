import SwiftUI

/// One row above the composer: Generate with its key, the thread actions,
/// feedback, and the keyboard hints toggle. Compact widths shrink the
/// secondary actions to icons.
struct QuickAssistToolbar: View {
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    let plan: QuickAssistStudioLayoutPlan
    @Binding var isKeyHintsVisible: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: actions.onGenerate) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Generate")
                    KeyCap(shortcut: ShortcutCatalog.quickAssist, emphasized: true)
                }
            }
            .buttonStyle(.overlayPrimary)
            .disabled(state.isLoading)
            .help("Answer the last question (\(ShortcutCatalog.quickAssist))")

            action("Follow up", systemImage: "arrowshape.turn.up.left", shortcut: ShortcutCatalog.quickAssistFollowUp, disabled: state.isLoading || !state.hasTurns, action: actions.onFollowUp)
            action("New thread", systemImage: "plus.bubble", shortcut: nil, disabled: state.isLoading, action: actions.onNewThread)
            action("Branch", systemImage: "arrow.triangle.branch", shortcut: nil, disabled: !state.hasTurns, action: actions.onCreateExperiment)
            if let threadID = state.activeThreadID, !threadID.isEmpty {
                action("Timeline", systemImage: "clock.arrow.circlepath", shortcut: nil, disabled: false) {
                    actions.onOpenTimeline(threadID)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if state.isLoading {
                ProgressView().controlSize(.small)
            }

            feedbackButtons

            Button {
                withAnimation(DesignTokens.Motion.focus) { isKeyHintsVisible.toggle() }
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.overlayIcon(isActive: isKeyHintsVisible))
            .help("Show keyboard shortcuts")
        }
    }

    private var feedbackButtons: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: actions.onAcceptTurn) {
                Image(systemName: state.feedbackStatus == .accepted ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.overlayIcon(isActive: state.feedbackStatus == .accepted))
            .disabled(state.isLoading || state.selectedTurnID == nil)
            .help("Mark this turn as good")

            Button(action: actions.onRejectTurn) {
                Image(systemName: state.feedbackStatus == .rejected ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .buttonStyle(.overlayIcon(isActive: state.feedbackStatus == .rejected))
            .disabled(state.isLoading || state.selectedTurnID == nil)
            .help("Mark this turn as off")
        }
    }

    @ViewBuilder
    private func action(
        _ title: String,
        systemImage: String,
        shortcut: String?,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let help = shortcut.map { "\(title) (\($0))" } ?? title
        if plan.toolbarUsesIconActions {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(.overlayIcon)
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(title)
        } else {
            Button(title, action: action)
                .buttonStyle(.overlay(.ghost))
                .disabled(disabled)
                .help(help)
        }
    }
}
