import Foundation

/// Document indexing for the store: runs the indexer off the main actor and
/// refreshes the cached details, unless the workspace vanished meanwhile.
extension WorkspaceStore {
    func loadDetails(for id: UUID) {
        documents[id] = database.loadWorkspaceDocuments(workspaceID: id)
        journal[id] = database.loadWorkspaceJournal(workspaceID: id)
    }

    func reindex(_ id: UUID) async {
        guard workspace(id: id) != nil else { return }
        guard !indexingIDs.contains(id) else {
            pendingReindexIDs.insert(id)
            return
        }
        indexingIDs.insert(id)
        defer {
            indexingIDs.remove(id)
            pendingReindexIDs.remove(id)
        }
        repeat {
            pendingReindexIDs.remove(id)
            guard let workspace = workspace(id: id) else { return }
            let indexer = self.indexer
            let folder = workspace.folderURL.standardizedFileURL
            // The first scan verifies persisted rows too: their previous
            // folder may have changed before this store or scan started.
            let verifyThisPass = verifiedIndexFolders[id] != folder
            // A partial pass can replace rows before its result arrives.
            // Restore provenance only after a successful current-folder scan.
            verifiedIndexFolders[id] = nil
            let report = await Task.detached(priority: .utility) {
                indexer.index(workspace, verifyContents: verifyThisPass)
            }.value
            guard let current = self.workspace(id: id) else {
                // Deleted while indexing: sweep rows written after the delete.
                do {
                    try database.deleteJobWorkspace(id: id)
                } catch {
                    lastError = "Could not finish index cleanup: \(error.localizedDescription)"
                }
                return
            }
            guard current.folderURL.standardizedFileURL == folder else {
                // A moved folder can contain different files with matching
                // size and modification dates. Verify content on the next pass.
                pendingReindexIDs.insert(id)
                continue
            }
            if report.failures.isEmpty {
                verifiedIndexFolders[id] = folder
            }
            indexReports[id] = report
            loadDetails(for: id)
        } while pendingReindexIDs.contains(id)
    }
}
