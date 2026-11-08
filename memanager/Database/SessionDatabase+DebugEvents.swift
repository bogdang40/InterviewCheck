import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Debug Events
    
    func insertDebugEvent(_ event: DebugEventRecord) {
        performAsync { db in
            guard let db else { return }
            
            let sql = """
            INSERT INTO debug_events 
            (session_id, event_type, event_category, event_name, details, stack_trace, 
             thread_info, memory_usage_mb, timestamp, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let sessionId = event.sessionId {
                    sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
                sqlite3_bind_text(stmt, 2, event.eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, event.eventCategory, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, event.eventName, -1, SQLITE_TRANSIENT)
                if let details = event.details {
                    sqlite3_bind_text(stmt, 5, details, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let stackTrace = event.stackTrace {
                    sqlite3_bind_text(stmt, 6, stackTrace, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let threadInfo = event.threadInfo {
                    sqlite3_bind_text(stmt, 7, threadInfo, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                if let memoryMB = event.memoryUsageMB {
                    sqlite3_bind_double(stmt, 8, memoryMB)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_int64(stmt, 9, Int64(event.timestamp.timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 10, Int64(Date().timeIntervalSince1970 * 1000))
                
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error inserting debug event: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }
    
    func getRecentDebugEvents(category: String? = nil, limit: Int = 100) -> [DebugEventRecord] {
        var events: [DebugEventRecord] = []
        
        performSync { db in
            guard let db else { return }
            
            var sql = """
            SELECT session_id, event_type, event_category, event_name, details, stack_trace,
                   thread_info, memory_usage_mb, timestamp
            FROM debug_events
            """
            
            if category != nil {
                sql += " WHERE event_category = ?"
            }
            sql += " ORDER BY timestamp DESC LIMIT ?"
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var bindIndex: Int32 = 1
                if let category = category {
                    sqlite3_bind_text(stmt, bindIndex, category, -1, SQLITE_TRANSIENT)
                    bindIndex += 1
                }
                sqlite3_bind_int(stmt, bindIndex, Int32(limit))
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sessionId = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                    let eventType = String(cString: sqlite3_column_text(stmt, 1))
                    let eventCategory = String(cString: sqlite3_column_text(stmt, 2))
                    let eventName = String(cString: sqlite3_column_text(stmt, 3))
                    let details = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let stackTrace = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    let threadInfo = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                    let memoryMB = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_double(stmt, 7) : nil
                    let timestamp = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)) / 1000)
                    
                    events.append(DebugEventRecord(
                        sessionId: sessionId,
                        eventType: eventType,
                        eventCategory: eventCategory,
                        eventName: eventName,
                        details: details,
                        stackTrace: stackTrace,
                        threadInfo: threadInfo,
                        memoryUsageMB: memoryMB,
                        timestamp: timestamp
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return events
    }
}
