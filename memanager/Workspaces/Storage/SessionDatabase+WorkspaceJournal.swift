import Foundation
import SQLite3

extension SessionDatabase {
    private static let workspaceJournalColumns =
        "id, workspace_id, kind, title, body, session_id, thread_id, turn_id, created_at"

    func insertWorkspaceJournalEntry(_ entry: WorkspaceJournalEntry) throws {
        try performSyncThrowing { db in
            let sql = """
            INSERT OR REPLACE INTO workspace_journal (\(Self.workspaceJournalColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(entry.id.uuidString, at: 1)
            statement.bindText(entry.workspaceID.uuidString, at: 2)
            statement.bindText(entry.kind.rawValue, at: 3)
            statement.bindText(entry.title, at: 4)
            statement.bindText(entry.body, at: 5)
            statement.bindOptionalText(entry.sessionID, at: 6)
            statement.bindOptionalText(entry.threadID, at: 7)
            statement.bindOptionalText(entry.turnID, at: 8)
            statement.bindMillis(entry.createdAt, at: 9)
            try statement.executeStep()
        }
    }

    /// Newest first so the prompt brief and the UI both read top down.
    func loadWorkspaceJournal(workspaceID: UUID, limit: Int = 200) -> [WorkspaceJournalEntry] {
        (try? performSyncThrowing { db in
            let sql = """
            SELECT \(Self.workspaceJournalColumns) FROM workspace_journal
            WHERE workspace_id = ? ORDER BY created_at DESC LIMIT ?
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(workspaceID.uuidString, at: 1)
            statement.bindInt(max(1, limit), at: 2)
            var results: [WorkspaceJournalEntry] = []
            while try statement.stepRow() {
                if let entry = makeWorkspaceJournalEntry(from: statement) {
                    results.append(entry)
                }
            }
            return results
        }) ?? []
    }

    func deleteWorkspaceJournalEntry(id: UUID) throws {
        try performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "DELETE FROM workspace_journal WHERE id = ?")
            statement.bindText(id.uuidString, at: 1)
            try statement.executeStep()
        }
    }

    func countWorkspaceJournalEntries(workspaceID: UUID) -> Int {
        (try? performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM workspace_journal WHERE workspace_id = ?")
            statement.bindText(workspaceID.uuidString, at: 1)
            return try statement.stepRow() ? statement.columnInt(0) : 0
        }) ?? 0
    }

    private func makeWorkspaceJournalEntry(from statement: SQLiteStatement) -> WorkspaceJournalEntry? {
        guard let rawID = statement.columnText(0), let id = UUID(uuidString: rawID),
              let rawWorkspaceID = statement.columnText(1), let workspaceID = UUID(uuidString: rawWorkspaceID) else {
            return nil
        }
        return WorkspaceJournalEntry(
            id: id,
            workspaceID: workspaceID,
            kind: WorkspaceJournalKind(rawValue: statement.columnText(2) ?? "") ?? .note,
            title: statement.columnText(3) ?? "",
            body: statement.columnText(4) ?? "",
            sessionID: statement.columnText(5),
            threadID: statement.columnText(6),
            turnID: statement.columnText(7),
            createdAt: statement.columnDate(8)
        )
    }
}
