import SwiftUI

/// The workspace list: a header with the live count and the two ways to add
/// material, then one selectable row per workspace, hot pipelines first.
struct WorkspaceListColumn: View {
    @ObservedObject var store: WorkspaceStore
    let selectedWorkspaceID: UUID?
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void
    let onImport: () -> Void

    private var workspaces: [JobWorkspace] {
        store.sortedWorkspaces
    }

    private var liveCount: Int {
        store.workspaces.reduce(0) { $0 + ($1.isArchived ? 0 : 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                SurfaceHeader("Workspaces", count: liveCount)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("New", systemImage: "plus", action: onCreate)
                        .buttonStyle(.overlay(.secondary, size: .small))
                        .fixedSize()
                        .help("New workspace folder")
                    Button("Import", systemImage: "folder.badge.plus", action: onImport)
                        .buttonStyle(.overlay(.secondary, size: .small))
                        .fixedSize()
                        .help("Import an existing folder")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            Hairline()
            if workspaces.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                list
            }
        }
        .background(OverlayPalette.surface)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.xxs) {
                ForEach(workspaces) { workspace in
                    SelectableRow(isSelected: workspace.id == selectedWorkspaceID, action: { onSelect(workspace.id) }) {
                        WorkspaceListRow(workspace: workspace, isActive: store.activeWorkspaceID == workspace.id)
                    }
                    .contextMenu { rowMenu(workspace) }
                }
            }
            .padding(DesignTokens.Spacing.sm)
        }
    }

    private var emptyState: some View {
        OverlayCompactEmptyState(
            systemImage: "folder.badge.plus",
            title: "No workspaces yet",
            message: "One folder per job. Create one, or import a folder you already keep.",
            action: EmptyStateAction(title: "New workspace", action: onCreate)
        )
        .padding(.top, DesignTokens.Spacing.lg)
    }

    @ViewBuilder
    private func rowMenu(_ workspace: JobWorkspace) -> some View {
        Button("Use for Quick Assist") { store.setActive(workspace.id) }
            .disabled(workspace.isArchived || store.activeWorkspaceID == workspace.id)
        Button("Reveal in Finder") { store.revealInFinder(workspace) }
    }
}
