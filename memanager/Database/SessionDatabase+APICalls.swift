import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - API Call Operations
    
    func insertAPICall(_ call: APICallRecord, ownershipID: UUID? = nil) {
        performAsync { db in
            guard let db else { return }
            if let ownershipID, !self.consumeAPICallOwnership(ownershipID, sessionId: call.sessionId) { return }
            
            let sql = """
            INSERT INTO api_calls 
            (session_id, call_type, provider, model, started_at, completed_at, duration_ms,
             input_tokens, output_tokens, total_tokens, status, error_message, 
             request_size_bytes, response_size_bytes, is_streaming, endpoint,
             system_prompt, request_payload, response_payload, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, call.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, call.callType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, call.provider, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, call.model, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 5, Int64(call.startedAt.timeIntervalSince1970 * 1000))
                if let completedAt = call.completedAt {
                    sqlite3_bind_int64(stmt, 6, Int64(completedAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let durationMs = call.durationMs {
                    sqlite3_bind_int64(stmt, 7, Int64(durationMs))
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_int(stmt, 8, Int32(call.inputTokens ?? 0))
                sqlite3_bind_int(stmt, 9, Int32(call.outputTokens ?? 0))
                sqlite3_bind_int(stmt, 10, Int32(call.totalTokens ?? 0))
                sqlite3_bind_text(stmt, 11, call.status, -1, SQLITE_TRANSIENT)
                if let errorMessage = call.errorMessage {
                    sqlite3_bind_text(stmt, 12, errorMessage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                sqlite3_bind_int(stmt, 13, Int32(call.requestSizeBytes ?? 0))
                sqlite3_bind_int(stmt, 14, Int32(call.responseSizeBytes ?? 0))
                sqlite3_bind_int(stmt, 15, call.isStreaming ? 1 : 0)
                sqlite3_bind_text(stmt, 16, call.endpoint, -1, SQLITE_TRANSIENT)
                // New payload columns
                if let systemPrompt = call.systemPrompt {
                    sqlite3_bind_text(stmt, 17, systemPrompt, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 17)
                }
                if let requestPayload = call.requestPayload {
                    sqlite3_bind_text(stmt, 18, requestPayload, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 18)
                }
                if let responsePayload = call.responsePayload {
                    sqlite3_bind_text(stmt, 19, responsePayload, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 19)
                }
                sqlite3_bind_int64(stmt, 20, Int64(Date().timeIntervalSince1970 * 1000))
                
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error inserting API call: \(String(cString: sqlite3_errmsg(db)))")
                    return
                }
                // A trigger can ignore the insert while still returning DONE.
                guard sqlite3_changes(db) == 1 else { return }
            } else {
                NSLog("[SessionDatabase] Error preparing API call insert: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            
            // Update provider stats
            self.updateProviderStats(call: call, db: db)
        }
    }
}
