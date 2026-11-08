import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Query Operations
    
    func getRecentSessions(limit: Int = 50) -> [SessionRecord] {
        var sessions: [SessionRecord] = []
        
        performSync { db in
            guard let db else { return }
            
            let sql = """
            SELECT id, started_at, ended_at, state, transcript, transcript_word_count,
                   screenshot_count, has_response, provider, model
            FROM sessions ORDER BY started_at DESC LIMIT ?
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    sessions.append(makeSessionRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return sessions
    }

    func getSessionRecord(id: String) -> SessionRecord? {
        performSync { db in
            guard let db else { return nil }

            let sql = """
            SELECT id, started_at, ended_at, state, transcript, transcript_word_count,
                   screenshot_count, has_response, provider, model
            FROM sessions WHERE id = ? LIMIT 1
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return makeSessionRecord(from: stmt)
        }
    }

    /// Shared row mapper for the canonical sessions column order
    /// (id, started_at, ended_at, state, transcript, transcript_word_count,
    /// screenshot_count, has_response, provider, model).
    private func makeSessionRecord(from stmt: OpaquePointer?) -> SessionRecord {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let startedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000)
        var endedAt: Date?
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            endedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
        }
        let state = String(cString: sqlite3_column_text(stmt, 3))
        let transcript = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let transcriptWordCount = Int(sqlite3_column_int(stmt, 5))
        let screenshotCount = Int(sqlite3_column_int(stmt, 6))
        let hasResponse = sqlite3_column_int(stmt, 7) == 1
        let provider = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let model = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

        return SessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            state: state,
            transcript: transcript,
            transcriptWordCount: transcriptWordCount,
            screenshotCount: screenshotCount,
            hasResponse: hasResponse,
            provider: provider,
            model: model
        )
    }
    
    func getProviderStats(days: Int = 30) -> [ProviderStatsRecord] {
        var stats: [ProviderStatsRecord] = []
        
        performSync { db in
            guard let db else { return }
            
            let sql = """
            SELECT date, provider, model, call_type, call_count, success_count, error_count,
                   total_duration_ms, total_input_tokens, total_output_tokens
            FROM provider_stats 
            WHERE date >= date('now', ?)
            ORDER BY date DESC, provider, model
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, "-\(days) days", -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let date = String(cString: sqlite3_column_text(stmt, 0))
                    let provider = String(cString: sqlite3_column_text(stmt, 1))
                    let model = String(cString: sqlite3_column_text(stmt, 2))
                    let callType = String(cString: sqlite3_column_text(stmt, 3))
                    let callCount = Int(sqlite3_column_int(stmt, 4))
                    let successCount = Int(sqlite3_column_int(stmt, 5))
                    let errorCount = Int(sqlite3_column_int(stmt, 6))
                    let totalDurationMs = Int(sqlite3_column_int64(stmt, 7))
                    let totalInputTokens = Int(sqlite3_column_int(stmt, 8))
                    let totalOutputTokens = Int(sqlite3_column_int(stmt, 9))
                    
                    stats.append(ProviderStatsRecord(
                        date: date,
                        provider: provider,
                        model: model,
                        callType: callType,
                        callCount: callCount,
                        successCount: successCount,
                        errorCount: errorCount,
                        totalDurationMs: totalDurationMs,
                        totalInputTokens: totalInputTokens,
                        totalOutputTokens: totalOutputTokens
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return stats
    }
    
    func getAPICallsForSession(sessionId: String) -> [APICallRecord] {
        var calls: [APICallRecord] = []
        
        performSync { db in
            guard let db else { return }
            
            let sql = """
            SELECT session_id, call_type, provider, model, started_at, completed_at, duration_ms,
                   input_tokens, output_tokens, total_tokens, status, error_message,
                   request_size_bytes, response_size_bytes, is_streaming, endpoint
            FROM api_calls WHERE session_id = ? ORDER BY started_at DESC
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sessionId = String(cString: sqlite3_column_text(stmt, 0))
                    let callType = String(cString: sqlite3_column_text(stmt, 1))
                    let provider = String(cString: sqlite3_column_text(stmt, 2))
                    let model = String(cString: sqlite3_column_text(stmt, 3))
                    let startedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)
                    var completedAt: Date?
                    if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                        completedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)) / 1000)
                    }
                    var durationMs: Int?
                    if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                        durationMs = Int(sqlite3_column_int64(stmt, 6))
                    }
                    let inputTokens = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil
                    let outputTokens = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 8)) : nil
                    let totalTokens = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 9)) : nil
                    let status = String(cString: sqlite3_column_text(stmt, 10))
                    let errorMessage = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
                    let requestSizeBytes = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 12)) : nil
                    let responseSizeBytes = sqlite3_column_type(stmt, 13) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 13)) : nil
                    let isStreaming = sqlite3_column_int(stmt, 14) == 1
                    let endpoint = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
                    
                    calls.append(APICallRecord(
                        sessionId: sessionId,
                        callType: callType,
                        provider: provider,
                        model: model,
                        startedAt: startedAt,
                        completedAt: completedAt,
                        durationMs: durationMs,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        totalTokens: totalTokens,
                        status: status,
                        errorMessage: errorMessage,
                        requestSizeBytes: requestSizeBytes,
                        responseSizeBytes: responseSizeBytes,
                        isStreaming: isStreaming,
                        endpoint: endpoint
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return calls
    }

}
