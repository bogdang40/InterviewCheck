import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Transcript Operations
    
    func insertTranscriptEntry(_ entry: TranscriptEntryRecord) {
        performAsync { db in
            guard let db else { return }
            
            let sql = """
            INSERT INTO transcript_entries 
            (session_id, speaker, text, timestamp, confidence, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, entry.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, entry.speaker, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, entry.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 4, Int64(entry.timestamp.timeIntervalSince1970 * 1000))
                if let confidence = entry.confidence {
                    sqlite3_bind_double(stmt, 5, confidence)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                sqlite3_bind_text(stmt, 6, entry.source, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970 * 1000))
                
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getTranscriptEntries(sessionId: String) -> [TranscriptEntryRecord] {
        var entries: [TranscriptEntryRecord] = []
        performSync { db in
            guard let db else { return }
            let sql = """
            SELECT speaker, text, timestamp, confidence, source
            FROM transcript_entries
            WHERE session_id = ?
            ORDER BY timestamp ASC
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let speaker = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "speaker"
                    let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let timestamp = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
                    let confidence = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
                    let source = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "microphone"
                    entries.append(
                        TranscriptEntryRecord(
                            sessionId: sessionId,
                            speaker: speaker,
                            text: text,
                            timestamp: timestamp,
                            confidence: confidence,
                            source: source
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return entries
    }
}
