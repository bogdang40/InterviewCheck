import AppKit
import Combine
import Foundation

/// Single source of truth for Job Workspaces on the main actor: the list,
/// the active selection, and folder lifecycle. Indexing and journal
/// operations live in the sibling extensions.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    static let activeWorkspaceKey = "memanager.activeWorkspaceID"

    @Published private(set) var workspaces: [JobWorkspace] = []
    @Published private(set) var activeWorkspaceID: UUID?
    @Published var documents: [UUID: [WorkspaceDocument]] = [:]
    @Published var journal: [UUID: [WorkspaceJournalEntry]] = [:]
    @Published var indexReports: [UUID: WorkspaceIndexReport] = [:]
    @Published var indexingIDs: Set<UUID> = []
    @Published var lastError: String?
    /// Failed metadata edits survive moving to another workspace.
    var metadataDrafts: [UUID: JobWorkspace] = [:]

    let database: SessionDatabase
    let indexer: WorkspaceDocumentIndexer
    let provisioner: WorkspaceFolderProvisioning
    var pendingReindexIDs = Set<UUID>()
    var verifiedIndexFolders: [UUID: URL] = [:]
    private let defaults: UserDefaults

    init(
        database: SessionDatabase = .shared,
        provisioner: WorkspaceFolderProvisioning = WorkspaceFolderProvisioner(),
        indexer: WorkspaceDocumentIndexer? = nil,
        defaults: UserDefaults = AppDefaults.standard
    ) {
        self.database = database
        self.provisioner = provisioner
        self.indexer = indexer ?? WorkspaceDocumentIndexer(database: database)
        self.defaults = defaults
        reload()
    }

    // MARK: - Reads

    var activeWorkspace: JobWorkspace? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == activeWorkspaceID })
    }

    var sortedWorkspaces: [JobWorkspace] {
        workspaces.sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
            if lhs.status.sortRank != rhs.status.sortRank { return lhs.status.sortRank < rhs.status.sortRank }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func workspace(id: UUID) -> JobWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    func reload() {
        workspaces = database.loadJobWorkspaces(includeArchived: true)
        let storedID = defaults.string(forKey: WorkspaceStore.activeWorkspaceKey).flatMap(UUID.init(uuidString:))
        activeWorkspaceID = storedID.flatMap { id in workspaces.contains(where: { $0.id == id && !$0.isArchived }) ? id : nil }
    }

    // MARK: - Lifecycle

    @discardableResult
    func createWorkspace(name: String, company: String, role: String, status: JobWorkspaceStatus = .researching) throws -> JobWorkspace {
        var workspace = JobWorkspace(name: name, company: company, role: role, status: status, folderPath: "")
        let folderURL = try provisioner.provision(workspace)
        workspace.folderPath = folderURL.path
        workspace.folderBookmark = WorkspaceStore.bookmark(for: folderURL)
        try database.upsertJobWorkspace(workspace)
        workspaces.append(workspace)
        setActive(workspace.id)
        loadDetails(for: workspace.id)
        return workspace
    }

    /// Adopts a folder the user picked. A folder that carries a manifest
    /// keeps its identity only when that identity is free or was moved.
    @discardableResult
    func importFolder(_ url: URL) throws -> JobWorkspace {
        try WorkspaceImportGuard.validate(url, rootDirectory: provisioner.rootDirectory)
        var workspace = WorkspaceManifest.read(from: url)?.makeWorkspace(folderURL: url)
            ?? JobWorkspace(name: url.lastPathComponent, folderPath: url.path)
        if let existing = workspaces.first(where: { $0.id == workspace.id }) {
            if WorkspaceImportGuard.shouldAdoptExistingIdentity(existingFolderPath: existing.folderPath, importedFolderPath: url.path) {
                workspace = existing
                workspace.folderPath = url.path
            } else {
                workspace = JobWorkspace(name: url.lastPathComponent, folderPath: url.path)
            }
        }
        try provisioner.adopt(existingFolder: url, for: workspace)
        workspace.folderBookmark = WorkspaceStore.bookmark(for: url)
        // Re-importing the folder of an archived workspace is how it comes back.
        workspace.isArchived = false
        workspace.updatedAt = Date()
        try database.upsertJobWorkspace(workspace)
        replaceOrAppend(workspace)
        setActive(workspace.id)
        Task { await reindex(workspace.id) }
        return workspace
    }

    /// Applies an edit to a workspace that still exists. A commit that was
    /// debounced past a delete is dropped rather than re-inserting the row
    /// and rewriting a manifest into a folder that may be in the Trash.
    @discardableResult
    func update(_ workspace: JobWorkspace) -> Bool {
        guard workspaces.contains(where: { $0.id == workspace.id }) else { return false }
        var updated = workspace
        updated.updatedAt = Date()
        do {
            try database.upsertJobWorkspace(updated)
            do {
                try provisioner.writeManifest(for: updated)
            } catch {
                lastError = "Changes saved in the app, but folder metadata could not be updated: \(error.localizedDescription)"
            }
            replaceOrAppend(updated)
            metadataDrafts[workspace.id] = nil
            return true
        } catch {
            lastError = error.localizedDescription
            if metadataDrafts[workspace.id] == nil { metadataDrafts[workspace.id] = workspace }
            return false
        }
    }

    /// Pass nil to clear. An archived or unknown id is ignored so a stray
    /// call cannot deactivate the workspace the user is working in.
    func setActive(_ id: UUID?) {
        guard let id else {
            activeWorkspaceID = nil
            defaults.removeObject(forKey: WorkspaceStore.activeWorkspaceKey)
            return
        }
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !workspaces[index].isArchived else { return }
        let openedAt = Date()
        workspaces[index].lastOpenedAt = openedAt
        activeWorkspaceID = id
        defaults.set(id.uuidString, forKey: WorkspaceStore.activeWorkspaceKey)
        database.touchJobWorkspaceOpened(id: id, at: openedAt)
    }

    func setArchived(_ id: UUID, archived: Bool) {
        guard var workspace = workspace(id: id) else { return }
        workspace.isArchived = archived
        guard update(workspace) else { return }
        if archived, activeWorkspaceID == id { setActive(nil) }
    }

    /// Removes the record. The folder is only moved to the Trash when asked,
    /// never deleted outright.
    func delete(_ id: UUID, moveFolderToTrash: Bool) {
        guard let workspace = workspace(id: id) else { return }
        do {
            try database.deleteJobWorkspace(id: id)
        } catch {
            lastError = error.localizedDescription
            return
        }
        if moveFolderToTrash {
            do {
                try FileManager.default.trashItem(at: workspace.folderURL, resultingItemURL: nil)
            } catch {
                lastError = "Workspace removed from the app, but its folder could not be moved to Trash: \(error.localizedDescription). The folder remains at \(workspace.folderPath)."
            }
        }
        workspaces.removeAll(where: { $0.id == id })
        documents[id] = nil
        journal[id] = nil
        indexReports[id] = nil
        verifiedIndexFolders[id] = nil
        metadataDrafts[id] = nil
        if activeWorkspaceID == id { setActive(nil) }
    }

    func revealInFinder(_ workspace: JobWorkspace) {
        NSWorkspace.shared.activateFileViewerSelecting([workspace.folderURL])
    }

    // MARK: - Internals

    private func replaceOrAppend(_ workspace: JobWorkspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
