import Foundation

extension SessionDatabase {
    /// One transaction for the whole selection, so an error leaves every
    /// selected conversation available for retry.
    func deleteQuickAssistThreads(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try performSyncThrowing { db in
            try withTransactionThrowing(db) {
                for id in ids.sorted() {
                    let statements = [
                        "UPDATE quick_assist_threads SET parent_thread_id = NULL, branched_from_turn_id = NULL WHERE parent_thread_id = ?",
                        "DELETE FROM quick_assist_calls WHERE thread_id = ?",
                        "DELETE FROM quick_assist_policy_events WHERE thread_id = ?",
                        "DELETE FROM quick_assist_thread_pins WHERE thread_id = ?",
                        "DELETE FROM quick_assist_threads WHERE id = ?"
                    ]
                    for sql in statements {
                        let statement = try SQLiteStatement(db: db, sql: sql)
                        statement.bindText(id, at: 1)
                        try statement.executeStep()
                    }
                }
            }
            invalidateQuickAssistCallOwnership(threadIDs: ids)
        }
    }
}
