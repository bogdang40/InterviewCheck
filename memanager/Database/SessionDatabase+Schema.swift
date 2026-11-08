import Foundation
import SQLite3

extension SessionDatabase {
    func createTables() {
        let createSQL = [
            SessionDatabaseSchema.sessionTables,
            SessionDatabaseSchema.memoryAndPracticeTables,
            SessionDatabaseSchema.workspaceTables,
            SessionDatabaseSchema.indexes
        ].joined(separator: "\n")
        
        executeSQL(createSQL)
        createMemoryFTSTableIfSupported()
        createKnowledgeFTSTableIfSupported()
    }
    
    func executeSQL(_ sql: String) {
        performSync { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                if let errMsg = errMsg {
                    NSLog("[SessionDatabase] SQL Error: \(String(cString: errMsg))")
                    sqlite3_free(errMsg)
                }
            }
        }
    }

    func createMemoryFTSTableIfSupported() {
        performSync { db in
            guard let db else { return }
            let sql = """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_nodes_fts
            USING fts5(node_id UNINDEXED, content, summary, tags, tokenize='porter');
            """
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK {
                memoryFTSSupported = true
            } else {
                memoryFTSSupported = false
                if let errMsg {
                    let message = String(cString: errMsg)
                    NSLog("[SessionDatabase] memory_nodes_fts unavailable: \(message)")
                    sqlite3_free(errMsg)
                }
            }
        }
    }

    /// Best effort FTS5 mirror of kg_nodes. When the SQLite build lacks FTS5
    /// the knowledge search falls back to LIKE scans, exactly like memory.
    func createKnowledgeFTSTableIfSupported() {
        performSync { db in
            guard let db else { return }
            let sql = """
            CREATE VIRTUAL TABLE IF NOT EXISTS kg_nodes_fts
            USING fts5(node_id UNINDEXED, label, summary, properties, tokenize='porter');
            """
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK {
                knowledgeFTSSupported = true
            } else {
                knowledgeFTSSupported = false
                if let errMsg {
                    NSLog("[SessionDatabase] kg_nodes_fts unavailable: \(String(cString: errMsg))")
                    sqlite3_free(errMsg)
                }
            }
        }
    }

    func ensureDeferredIndices() {
        guard columnExists(table: "quick_assist_calls", column: "experiment_group_id") else {
            return
        }

        executeSQL(
            "CREATE INDEX IF NOT EXISTS idx_quick_assist_calls_experiment_group ON quick_assist_calls(experiment_group_id, started_at);"
        )
    }
}
