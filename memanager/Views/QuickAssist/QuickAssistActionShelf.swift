import SwiftUI

/// The primary action never scrolls out of reach. At narrow widths the
/// three context destinations occupy a second, fully labelled row.
struct QuickAssistActionShelf: View {
    @Environment(\.floatingDockLayout) private var floatingDock
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    let onAsk: () -> Void
    let onSources: () -> Void
    let onTranscript: () -> Void
    let onConversation: () -> Void
    let onOptions: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                contextActions
                copyAction
                moreActions
                Spacer(minLength: 10)
                primaryAction
            }
            .frame(minWidth: 418)
            VStack(spacing: 6) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    contextActions
                    Spacer(minLength: 4)
                    moreActions
                }
                HStack(spacing: DesignTokens.Spacing.xs) {
                    copyAction
                    Spacer(minLength: 0)
                    primaryAction
                }
            }
        }
        .buttonStyle(.overlay(.ghost, size: .small))
        .padding(.horizontal, 16)
        .padding(.vertical, floatingDock == nil ? 12 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(floatingDock == nil ? OverlayPalette.surfaceRaised : .clear)
    }

    @ViewBuilder private var contextActions: some View {
        Button("Sources", systemImage: "doc.text", action: onSources)
            .accessibilityIdentifier("assist.sources")
        Button("Transcript", systemImage: "text.alignleft", action: onTranscript)
            .accessibilityIdentifier("assist.transcript")
    }

    @ViewBuilder private var primaryAction: some View {
        if state.isLoading {
            Button("Cancel generation", systemImage: "stop.circle", action: actions.onCancel)
                .buttonStyle(.overlay(.secondary))
                .accessibilityIdentifier("assist.cancel")
        } else {
            Button(action: onAsk) {
                HStack(spacing: 8) {
                    Text(state.hasTurns ? "Ask follow up" : "Ask question")
                    Image(systemName: "arrow.up.right")
                }
            }
            .buttonStyle(.overlayPrimary)
            .accessibilityIdentifier("assist.ask")
        }
    }

    private var copyAction: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            QuickAssistClipboard().copy(state.copyableResponse)
        }
        .disabled(state.copyableResponse.isEmpty)
        .accessibilityIdentifier("assist.copy")
    }

    private var moreActions: some View {
        Menu {
            Button("Conversation", systemImage: "bubble.left.and.bubble.right", action: onConversation)
            Button("Answer options", systemImage: "slider.horizontal.3", action: onOptions)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More answer actions")
        .accessibilityIdentifier("assist.more")
        .help("Conversation and answer options")
    }
}
