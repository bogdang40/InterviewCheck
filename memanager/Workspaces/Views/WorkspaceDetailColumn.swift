import SwiftUI

enum WorkspaceDetailTab: String, CaseIterable, Identifiable {
    case overview, documents, journal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Role brief, source files and journal each have their own reading surface.
struct WorkspaceDetailColumn: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: JobWorkspace
    var breakpoint: OverlayLayout.Breakpoint = .regular
    @State private var selectedTab: WorkspaceDetailTab = .overview
    @State private var isDeleteConfirmationPresented = false
    @State private var isJournalSheetPresented = false
    @State private var bindMessage: WorkspaceBindMessage?

    init(store: WorkspaceStore, workspace: JobWorkspace, breakpoint: OverlayLayout.Breakpoint = .regular, initialTab: WorkspaceDetailTab = .overview) {
        self.store = store
        self.workspace = workspace
        self.breakpoint = breakpoint
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentStrip(items: WorkspaceDetailTab.allCases.map { SegmentItem(id: $0, title: $0.title) }, selection: $selectedTab)
                .padding(DesignTokens.Spacing.md)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let message = bindMessage {
                        ToneBanner(tone: message.tone, message: message.text, onDismiss: { bindMessage = nil })
                    }
                    retainedTab(.overview) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                            WorkspaceMetadataForm(store: store, workspace: workspace, breakpoint: breakpoint)
                            sourceReadiness
                            folderLine
                        }
                    }
                    retainedTab(.documents) {
                        WorkspaceDocumentsSection(
                            documents: store.documents[workspace.id] ?? [],
                            report: store.indexReports[workspace.id],
                            isIndexing: store.indexingIDs.contains(workspace.id),
                            onReindex: { Task { await store.reindex(workspace.id) } },
                            onReveal: { store.revealInFinder(workspace) }
                        )
                    }
                    retainedTab(.journal) {
                        WorkspaceJournalSection(
                            entries: store.journal[workspace.id] ?? [],
                            onAdd: { isJournalSheetPresented = true },
                            onDelete: { store.deleteJournalEntry($0) }
                        )
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
            Hairline()
            WorkspaceActionsRow(
                workspace: workspace,
                isActive: store.activeWorkspaceID == workspace.id,
                onUse: { store.setActive(workspace.id) },
                onReveal: { store.revealInFinder(workspace) },
                onBind: bindFolder,
                onArchive: { store.setArchived(workspace.id, archived: !workspace.isArchived) },
                onDelete: { isDeleteConfirmationPresented = true }
            )
            .padding(DesignTokens.Spacing.md)
        }
        .onAppear { store.loadDetails(for: workspace.id) }
        .onChange(of: workspace.id) { _, newID in
            bindMessage = nil
            store.loadDetails(for: newID)
        }
        .sheet(isPresented: $isJournalSheetPresented) {
            WorkspaceJournalEntrySheet { kind, title, body in
                try store.addJournalEntry(kind: kind, title: title, body: body, to: workspace.id)
            }
        }
        .confirmationDialog("Remove \(workspace.displayTitle)?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Remove from Abley, keep folder", role: .destructive) { store.delete(workspace.id, moveFolderToTrash: false) }
            Button("Remove and move folder to Trash", role: .destructive) { store.delete(workspace.id, moveFolderToTrash: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app index and journal rows are removed. Files remain in their folder unless you choose Trash.")
        }
    }

    private func retainedTab<Content: View>(_ tab: WorkspaceDetailTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: selectedTab == tab ? nil : 0, alignment: .top)
            .clipped()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .disabled(selectedTab != tab)
            .accessibilityHidden(selectedTab != tab)
    }

    private var sourceReadiness: some View {
        Button { selectedTab = .documents } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Label("Source readiness", systemImage: "doc.text")
                Spacer(minLength: 0)
                Text("\(store.documents[workspace.id]?.count ?? 0) indexed")
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.overlaySecondary)
        .help("Review extracted text, skipped files and indexing failures")
    }

    private var folderLine: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Workspace folder", systemImage: "folder")
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
            Text(workspace.folderPath)
                .font(OverlayType.mono)
                .foregroundStyle(OverlayPalette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Using this workspace affects future requests. It does not change sources recorded with earlier answers.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
    }

    private func bindFolder() {
        bindMessage = WorkspaceBindMessageResolver.message(for: WorkspaceQuickAssistBridge.shared.bindFolderToActiveModeTools(workspace))
    }
}
