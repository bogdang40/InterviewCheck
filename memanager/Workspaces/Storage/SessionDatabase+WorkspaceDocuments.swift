import Foundation
import SQLite3

extension SessionDatabase {
    private static let workspaceDocumentColumns =
        "id, workspace_id, relative_path, kind, category, byte_size, sha256, extracted_text, extracted_truncated, indexed_at, modified_at"

    /// Path is the natural key inside a workspace. A re-index that finds the
    /// same path keeps the existing row id (callers pass it back in).
    func upsertWorkspaceDocument(_ document: WorkspaceDocument) throws {
        try performSyncThrowing { db in
            let sql = """
            INSERT INTO workspace_documents (\(Self.workspaceDocumentColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(workspace_id, relative_path) DO UPDATE SET
                kind = excluded.kind,
                category = excluded.category,
                byte_size = excluded.byte_size,
                sha256 = excluded.sha256,
                extracted_text = excluded.extracted_text,
                extracted_truncated = excluded.extracted_truncated,
                indexed_at = excluded.indexed_at,
                modified_at = excluded.modified_at
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(document.id.uuidString, at: 1)
            statement.bindText(document.workspaceID.uuidString, at: 2)
            statement.bindText(document.relativePath, at: 3)
            statement.bindText(document.kind.rawValue, at: 4)
            statement.bindText(document.category.rawValue, at: 5)
            statement.bindInt64(Int64(document.byteSize), at: 6)
            statement.bindText(document.sha256, at: 7)
            statement.bindOptionalText(document.extractedText, at: 8)
            statement.bindBool(document.extractedTruncated, at: 9)
            statement.bindMillis(document.indexedAt, at: 10)
            statement.bindMillis(document.modifiedAt, at: 11)
            try statement.executeStep()
        }
    }

    func loadWorkspaceDocuments(workspaceID: UUID) -> [WorkspaceDocument] {
        (try? performSyncThrowing { db in
            let sql = """
            SELECT \(Self.workspaceDocumentColumns) FROM workspace_documents
            WHERE workspace_id = ? ORDER BY category, relative_path
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(workspaceID.uuidString, at: 1)
            var results: [WorkspaceDocument] = []
            while try statement.stepRow() {
                if let document = makeWorkspaceDocument(from: statement) {
                    results.append(document)
                }
            }
            return results
        }) ?? []
    }

    func deleteWorkspaceDocuments(workspaceID: UUID, relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try performSyncThrowing { db in
            try withTransactionThrowing(db) {
                for path in relativePaths {
                    let statement = try SQLiteStatement(
                        db: db,
                        sql: "DELETE FROM workspace_documents WHERE workspace_id = ? AND relative_path = ?"
                    )
                    statement.bindText(workspaceID.uuidString, at: 1)
                    statement.bindText(path, at: 2)
                    try statement.executeStep()
                }
            }
        }
    }

    func countWorkspaceDocuments(workspaceID: UUID) -> Int {
        (try? performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM workspace_documents WHERE workspace_id = ?")
            statement.bindText(workspaceID.uuidString, at: 1)
            return try statement.stepRow() ? statement.columnInt(0) : 0
        }) ?? 0
    }

    private func makeWorkspaceDocument(from statement: SQLiteStatement) -> WorkspaceDocument? {
        guard let rawID = statement.columnText(0), let id = UUID(uuidString: rawID),
              let rawWorkspaceID = statement.columnText(1), let workspaceID = UUID(uuidString: rawWorkspaceID) else {
            return nil
        }
        return WorkspaceDocument(
            id: id,
            workspaceID: workspaceID,
            relativePath: statement.columnText(2) ?? "",
            kind: WorkspaceDocumentKind(rawValue: statement.columnText(3) ?? "") ?? .other,
            category: WorkspaceDocumentCategory(rawValue: statement.columnText(4) ?? "") ?? .other,
            byteSize: Int(statement.columnInt64(5)),
            sha256: statement.columnText(6) ?? "",
            extractedText: statement.columnText(7),
            extractedTruncated: statement.columnBool(8),
            indexedAt: statement.columnDate(9),
            modifiedAt: statement.columnDate(10)
        )
    }
}
