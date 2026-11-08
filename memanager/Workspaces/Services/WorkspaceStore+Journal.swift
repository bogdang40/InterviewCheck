import Foundation

/// Manual journal entries and cache refresh after automatic ones.
extension WorkspaceStore {
    func addJournalEntry(kind: WorkspaceJournalKind, title: String, body: String, to id: UUID) throws {
        guard let workspace = workspace(id: id) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let entry = WorkspaceJournalEntry(workspaceID: id, kind: kind, title: title, body: body)
        if let warning = try WorkspaceJournalRecorder(database: database).recordManualEntry(entry, in: workspace) {
            lastError = "Entry saved in the app, but its Markdown copy could not be written. \(warning)"
        }
        loadDetails(for: id)
    }

    func deleteJournalEntry(_ entry: WorkspaceJournalEntry) {
        do {
            try database.deleteWorkspaceJournalEntry(id: entry.id)
        } catch {
            lastError = "Could not remove journal entry: \(error.localizedDescription)"
            return
        }
        loadDetails(for: entry.workspaceID)
    }

    /// Called by the Quick Assist bridge after it appends an entry off the store.
    func noteJournalChanged(for id: UUID) {
        loadDetails(for: id)
    }
}
