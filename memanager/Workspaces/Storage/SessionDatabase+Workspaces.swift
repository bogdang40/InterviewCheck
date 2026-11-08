import Foundation
import SQLite3

/// Job workspace rows. Documents and journal entries live in sibling
/// extensions; this file owns only the workspace table.
extension SessionDatabase {
    private static let jobWorkspaceColumns =
        "id, name, company, role, status, folder_path, folder_bookmark, job_description_summary, notes, tags, created_at, updated_at, last_opened_at, is_archived"

    func upsertJobWorkspace(_ workspace: JobWorkspace) throws {
        try performSyncThrowing { db in
            let sql = """
            INSERT INTO job_workspaces (\(Self.jobWorkspaceColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                company = excluded.company,
                role = excluded.role,
                status = excluded.status,
                folder_path = excluded.folder_path,
                folder_bookmark = excluded.folder_bookmark,
                job_description_summary = excluded.job_description_summary,
                notes = excluded.notes,
                tags = excluded.tags,
                updated_at = excluded.updated_at,
                is_archived = excluded.is_archived
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(workspace.id.uuidString, at: 1)
            statement.bindText(workspace.name, at: 2)
            statement.bindText(workspace.company, at: 3)
            statement.bindText(workspace.role, at: 4)
            statement.bindText(workspace.status.rawValue, at: 5)
            statement.bindText(workspace.folderPath, at: 6)
            statement.bindOptionalBlob(workspace.folderBookmark, at: 7)
            statement.bindOptionalText(workspace.jobDescriptionSummary, at: 8)
            statement.bindText(workspace.notes, at: 9)
            statement.bindOptionalText(encodeStringArray(workspace.tags), at: 10)
            statement.bindMillis(workspace.createdAt, at: 11)
            statement.bindMillis(workspace.updatedAt, at: 12)
            statement.bindOptionalMillis(workspace.lastOpenedAt, at: 13)
            statement.bindBool(workspace.isArchived, at: 14)
            try statement.executeStep()
        }
    }

    func loadJobWorkspaces(includeArchived: Bool = false) -> [JobWorkspace] {
        (try? performSyncThrowing { db in
            let filter = includeArchived ? "" : "WHERE is_archived = 0"
            let sql = "SELECT \(Self.jobWorkspaceColumns) FROM job_workspaces \(filter) ORDER BY updated_at DESC"
            let statement = try SQLiteStatement(db: db, sql: sql)
            var results: [JobWorkspace] = []
            while try statement.stepRow() {
                if let workspace = makeJobWorkspace(from: statement) {
                    results.append(workspace)
                }
            }
            return results
        }) ?? []
    }

    func loadJobWorkspace(id: UUID) -> JobWorkspace? {
        try? performSyncThrowing { db in
            let sql = "SELECT \(Self.jobWorkspaceColumns) FROM job_workspaces WHERE id = ? LIMIT 1"
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(id.uuidString, at: 1)
            guard try statement.stepRow() else { return nil }
            return makeJobWorkspace(from: statement)
        }
    }

    func touchJobWorkspaceOpened(id: UUID, at date: Date = Date()) {
        do {
            try performSyncThrowing { db in
                let statement = try SQLiteStatement(db: db, sql: "UPDATE job_workspaces SET last_opened_at = ? WHERE id = ?")
                statement.bindMillis(date, at: 1)
                statement.bindText(id.uuidString, at: 2)
                try statement.executeStep()
            }
        } catch {
            reportSwallowedError(error, operation: "touchJobWorkspaceOpened")
        }
    }

    /// Removes the workspace row and everything indexed under it. Files on
    /// disk are never touched here; that is the caller's explicit decision.
    func deleteJobWorkspace(id: UUID) throws {
        try performSyncThrowing { db in
            try withTransactionThrowing(db) {
                for table in ["workspace_documents", "workspace_journal"] {
                    let statement = try SQLiteStatement(db: db, sql: "DELETE FROM \(table) WHERE workspace_id = ?")
                    statement.bindText(id.uuidString, at: 1)
                    try statement.executeStep()
                }
                let statement = try SQLiteStatement(db: db, sql: "DELETE FROM job_workspaces WHERE id = ?")
                statement.bindText(id.uuidString, at: 1)
                try statement.executeStep()
            }
        }
    }

    private func makeJobWorkspace(from statement: SQLiteStatement) -> JobWorkspace? {
        guard let rawID = statement.columnText(0), let id = UUID(uuidString: rawID) else { return nil }
        return JobWorkspace(
            id: id,
            name: statement.columnText(1) ?? "",
            company: statement.columnText(2) ?? "",
            role: statement.columnText(3) ?? "",
            status: JobWorkspaceStatus(rawValue: statement.columnText(4) ?? "") ?? .researching,
            folderPath: statement.columnText(5) ?? "",
            folderBookmark: statement.columnBlob(6),
            jobDescriptionSummary: statement.columnText(7),
            notes: statement.columnText(8) ?? "",
            tags: decodeStringArray(statement.columnText(9)),
            createdAt: statement.columnDate(10),
            updatedAt: statement.columnDate(11),
            lastOpenedAt: statement.columnOptionalDate(12),
            isArchived: statement.columnBool(13)
        )
    }
}
