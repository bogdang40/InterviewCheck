import Foundation
import SQLite3

extension SessionDatabase {
    /// Remove the session and its recorded evidence atomically. Saved practice,
    /// workspace and knowledge content have independent lifetimes.
    func deleteSession(id: String) throws {
        try deleteSessions(ids: [id])
    }

    func deleteSessions(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try performSyncThrowing { db in
            var removedThreadIDs = Set<String>()
            try withTransactionThrowing(db) {
                for id in ids.sorted() {
                    try deleteSessionStatements(id: id, db: db, removedThreadIDs: &removedThreadIDs)
                }
            }
            invalidateQuickAssistCallOwnership(sessionIDs: ids, threadIDs: removedThreadIDs)
            invalidateAPICallOwnership(sessionIDs: ids)
        }
    }

    private func deleteSessionStatements(
        id: String, db: OpaquePointer, removedThreadIDs: inout Set<String>
    ) throws {
        func run(_ sql: String, value: String? = nil) throws {
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(value ?? id, at: 1)
            try statement.executeStep()
        }

        let affected = try SQLiteStatement(db: db, sql: """
            SELECT id FROM quick_assist_threads WHERE origin_session_id = ?1
            UNION SELECT thread_id FROM quick_assist_calls WHERE session_id = ?1
            """)
        affected.bindText(id, at: 1)
        var affectedThreadIDs: [String] = []
        while try affected.stepRow() {
            if let threadID = affected.columnText(0) { affectedThreadIDs.append(threadID) }
        }

        try run("""
            DELETE FROM memory_relationships
            WHERE from_node_id IN (SELECT id FROM memory_nodes WHERE session_id = ?1)
               OR to_node_id IN (SELECT id FROM memory_nodes WHERE session_id = ?1)
            """)
        try run("DELETE FROM quick_assist_thread_pins WHERE memory_node_id IN (SELECT id FROM memory_nodes WHERE session_id = ?)")
        if memoryFTSSupported {
            try run("DELETE FROM memory_nodes_fts WHERE node_id IN (SELECT id FROM memory_nodes WHERE session_id = ?)")
        }
        // A conversation can span sessions. Remove only this session's
        // turns, then remove empty threads originating in it.
        try run("""
            UPDATE quick_assist_threads SET branched_from_turn_id = NULL
            WHERE branched_from_turn_id IN (SELECT turn_id FROM quick_assist_calls WHERE session_id = ?)
            """)
        let tables = [
            "session_summary_action_items", "session_summaries", "session_mode_snapshots",
            "session_tool_calls", "session_debrief_drills", "session_debriefs", "session_snapshots",
            "quick_assist_calls", "quick_assist_policy_events", "quick_assist_experiments",
            "transcript_entries", "screenshots", "api_calls", "debug_events",
            "coach_findings", "memory_retrieval_events", "memory_nodes"
        ]
        for table in tables {
            try run("DELETE FROM \(table) WHERE session_id = ?")
        }
        for threadID in affectedThreadIDs {
            let emptyThread = """
                SELECT id FROM quick_assist_threads WHERE id = ?1
                AND NOT EXISTS (SELECT 1 FROM quick_assist_calls WHERE thread_id = quick_assist_threads.id)
                """
            try run("DELETE FROM quick_assist_thread_pins WHERE thread_id IN (\(emptyThread))", value: threadID)
            try run("UPDATE quick_assist_threads SET parent_thread_id = NULL WHERE parent_thread_id IN (\(emptyThread))", value: threadID)
            try run("DELETE FROM quick_assist_threads WHERE id IN (\(emptyThread))", value: threadID)
            if sqlite3_changes(db) > 0 { removedThreadIDs.insert(threadID) }
        }
        try run("UPDATE quick_assist_threads SET origin_session_id = NULL WHERE origin_session_id = ?")
        try run("UPDATE workspace_journal SET session_id = NULL WHERE session_id = ?")
        try run("DELETE FROM sessions WHERE id = ?")
    }
}
