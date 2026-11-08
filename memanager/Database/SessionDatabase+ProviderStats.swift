import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Provider Stats
    
    func updateProviderStats(call: APICallRecord, db: OpaquePointer?) {
        guard let db = db else { return }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: call.startedAt)
        
        let isSuccess = call.status == "success"
        let durationMs = call.durationMs ?? 0
        
        // Try to update existing record
        let updateSQL = """
        UPDATE provider_stats SET
            call_count = call_count + 1,
            success_count = success_count + ?,
            error_count = error_count + ?,
            total_duration_ms = total_duration_ms + ?,
            total_input_tokens = total_input_tokens + ?,
            total_output_tokens = total_output_tokens + ?,
            updated_at = ?
        WHERE date = ? AND provider = ? AND model = ? AND call_type = ?
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, isSuccess ? 1 : 0)
            sqlite3_bind_int(stmt, 2, isSuccess ? 0 : 1)
            sqlite3_bind_int64(stmt, 3, Int64(durationMs))
            sqlite3_bind_int(stmt, 4, Int32(call.inputTokens ?? 0))
            sqlite3_bind_int(stmt, 5, Int32(call.outputTokens ?? 0))
            sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 7, dateStr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, call.provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, call.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, call.callType, -1, SQLITE_TRANSIENT)
            
            sqlite3_step(stmt)
            let changes = sqlite3_changes(db)
            sqlite3_finalize(stmt)
            
            // If no rows updated, insert new record
            if changes == 0 {
                let insertSQL = """
                INSERT INTO provider_stats 
                (date, provider, model, call_type, call_count, success_count, error_count,
                 total_duration_ms, total_input_tokens, total_output_tokens, avg_duration_ms,
                 created_at, updated_at)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                
                var insertStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    sqlite3_bind_text(insertStmt, 1, dateStr, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 2, call.provider, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 3, call.model, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 4, call.callType, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 5, isSuccess ? 1 : 0)
                    sqlite3_bind_int(insertStmt, 6, isSuccess ? 0 : 1)
                    sqlite3_bind_int64(insertStmt, 7, Int64(durationMs))
                    sqlite3_bind_int(insertStmt, 8, Int32(call.inputTokens ?? 0))
                    sqlite3_bind_int(insertStmt, 9, Int32(call.outputTokens ?? 0))
                    sqlite3_bind_double(insertStmt, 10, Double(durationMs))
                    sqlite3_bind_int64(insertStmt, 11, now)
                    sqlite3_bind_int64(insertStmt, 12, now)
                    
                    sqlite3_step(insertStmt)
                }
                sqlite3_finalize(insertStmt)
            }
        } else {
            sqlite3_finalize(stmt)
        }
    }
}
