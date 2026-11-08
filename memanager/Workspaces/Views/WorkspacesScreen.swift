import SwiftUI
import UniformTypeIdentifiers

/// Overlay screen for Job Workspaces: the list beside the selected
/// workspace from the regular breakpoint up, one pane at a time below it.
struct WorkspacesScreen: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var selectedWorkspaceID: UUID?
    @State private var pane: MasterDetailPane = .list
    @State private var isCreateSheetPresented = false
    @State private var isImporterPresented = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            OverlayMasterDetail(width: width, pane: $pane, listTitle: "Workspaces", detailTitle: "Detail") {
                WorkspaceListColumn(
                    store: store,
                    selectedWorkspaceID: selectedWorkspaceID,
                    onSelect: { id in
                        selectedWorkspaceID = id
                        pane = MasterDetailLayoutResolver.pane(afterSelectionIn: width, current: pane)
                    },
                    onCreate: { isCreateSheetPresented = true },
                    onImport: { isImporterPresented = true }
                )
            } detail: {
                if let workspace = resolvedSelection() {
                    WorkspaceDetailColumn(
                        store: store,
                        workspace: workspace,
                        breakpoint: OverlayLayout.breakpoint(for: width)
                    )
                } else {
                    placeholder
                }
            }
        }
        .onAppear {
            store.reload()
            resyncSelection()
        }
        .onChange(of: store.workspaces) { _, _ in resyncSelection() }
        .sheet(isPresented: $isCreateSheetPresented) {
            WorkspaceCreateSheet(store: store) { created in
                showDetail(of: created.id)
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            handleImport(result)
        }
        .alert("Workspace error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private var placeholder: some View {
        OverlayEmptyState(
            systemImage: "folder.badge.person.crop",
            title: "One folder per job",
            message: "Keep a role brief, source files and a journal together. Indexed text can inform future Quick Assist requests when you activate the workspace.",
            primary: EmptyStateAction(title: "New workspace", action: { isCreateSheetPresented = true }),
            secondary: EmptyStateAction(title: "Import folder", action: { isImporterPresented = true })
        )
    }

    private func resolvedSelection() -> JobWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return store.workspace(id: selectedWorkspaceID)
    }

    private func resyncSelection() {
        selectedWorkspaceID = WorkspaceSelectionResolver.resolve(
            current: selectedWorkspaceID,
            active: store.activeWorkspaceID,
            sorted: store.sortedWorkspaces
        )
    }

    /// A workspace the user just added is what they want to look at, and
    /// on a single pane layout that means the detail pane.
    private func showDetail(of id: UUID) {
        selectedWorkspaceID = id
        pane = .detail
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try store.importFolder(url)
                showDetail(of: imported.id)
            } catch {
                store.lastError = error.localizedDescription
            }
        case .failure(let error):
            store.lastError = error.localizedDescription
        }
    }
}
