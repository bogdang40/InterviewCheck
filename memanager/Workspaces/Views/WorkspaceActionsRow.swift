import SwiftUI

/// Everything the user can do with a workspace: the primary action first,
/// the quiet ones after it, and the destructive one at the far edge. Folds
/// onto two lines when the detail column is narrow.
struct WorkspaceActionsRow: View {
    let workspace: JobWorkspace
    let isActive: Bool
    let onUse: () -> Void
    let onReveal: () -> Void
    let onBind: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        WrappingFlowLayout(spacing: DesignTokens.Spacing.sm) {
            primary
            Button("Give tools access", action: onBind)
                .buttonStyle(.overlaySecondary)
                .help("Point the active Mode's project folder tools at this workspace folder")
            Button("Open folder", action: onReveal)
                .buttonStyle(.overlaySecondary)
            Menu {
                Button(workspace.isArchived ? "Unarchive" : "Archive", action: onArchive)
                Divider()
                Button("Remove workspace", role: .destructive, action: onDelete)
            } label: {
                Label("Workspace actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var primary: some View {
        if isActive {
            ToneBadge(text: "Active for Quick Assist", tone: .success, systemImage: "checkmark")
        } else {
            Button("Use for Quick Assist", action: onUse)
                .buttonStyle(.overlayPrimary)
                .disabled(workspace.isArchived)
                .help(workspace.isArchived ? "Unarchive the workspace before using it" : "Ground Quick Assist in this folder")
        }
    }

}
