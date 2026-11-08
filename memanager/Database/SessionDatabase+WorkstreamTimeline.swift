import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Workstream Timeline

    func getWorkstreamTimeline(filter: WorkstreamTimelineFilter) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        let searchLike = makeSearchLikeValue(from: filter.searchQuery)
        let normalizedLimit = max(20, min(filter.limit, 1000))

        performSync { db in
            guard let db else { return }

            let sessionScope = resolveSessionScope(filter: filter, db: db)
            let hasThreadScope = filter.threadId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            // An unresolved thread has no session context. Treating nil as an
            // unfiltered session query would expose every session's artifacts.
            let includeSessionEvents = !hasThreadScope || sessionScope != nil
            events.append(contentsOf: fetchQuickAssistTimelineEvents(
                db: db,
                filter: filter,
                searchLike: searchLike,
                limit: normalizedLimit
            ))
            events.append(contentsOf: fetchQuickAssistPolicyTimelineEvents(
                db: db,
                filter: filter,
                searchLike: searchLike,
                limit: max(20, normalizedLimit / 3)
            ))
            if includeSessionEvents {
                events.append(contentsOf: fetchTranscriptTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    searchLike: searchLike,
                    limit: max(20, normalizedLimit / 3)
                ))
            }
            if includeSessionEvents {
                events.append(contentsOf: fetchScreenshotTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    limit: max(12, normalizedLimit / 4)
                ))
            }
            if includeSessionEvents {
                events.append(contentsOf: fetchResponseCardTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    limit: max(12, normalizedLimit / 4)
                ))
            }
            events.append(contentsOf: fetchExperimentTimelineEvents(
                db: db,
                sessionId: sessionScope,
                threadId: filter.threadId,
                limit: max(12, normalizedLimit / 4)
            ))
            if includeSessionEvents {
                events.append(contentsOf: fetchMemoryTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    searchLike: searchLike,
                    limit: max(16, normalizedLimit / 3)
                ))
            }
            events.append(contentsOf: fetchMemoryRetrievalTimelineEvents(
                db: db,
                sessionId: sessionScope,
                threadId: filter.threadId,
                searchLike: searchLike,
                limit: max(16, normalizedLimit / 3)
            ))
            if filter.includeDebugEvents && includeSessionEvents {
                events.append(contentsOf: fetchDebugTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    searchLike: searchLike,
                    limit: max(16, normalizedLimit / 3)
                ))
            }
            events.append(contentsOf: fetchCoachTimelineEvents(
                db: db,
                filter: filter,
                searchLike: searchLike,
                limit: max(12, normalizedLimit / 3)
            ))
            if includeSessionEvents {
                events.append(contentsOf: fetchDebriefTimelineEvents(
                    db: db,
                    sessionId: sessionScope,
                    limit: max(8, normalizedLimit / 5)
                ))
            }
        }

        events.sort { $0.timestamp > $1.timestamp }
        if events.count > normalizedLimit {
            return Array(events.prefix(normalizedLimit))
        }
        return events
    }

    private func makeSearchLikeValue(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "%\(trimmed.lowercased())%"
    }

    private func resolveSessionScope(filter: WorkstreamTimelineFilter, db: OpaquePointer) -> String? {
        if let explicitSession = filter.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitSession.isEmpty {
            return explicitSession
        }

        guard let threadId = filter.threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadId.isEmpty else {
            return nil
        }

        var resolvedSessionId: String?
        let sql = """
        SELECT COALESCE(origin_session_id, (
            SELECT session_id FROM quick_assist_calls c
            WHERE c.thread_id = quick_assist_threads.id
            ORDER BY c.started_at DESC
            LIMIT 1
        ))
        FROM quick_assist_threads
        WHERE id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, threadId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let text = sqlite3_column_text(stmt, 0) {
                resolvedSessionId = String(cString: text)
            }
        }
        sqlite3_finalize(stmt)
        return resolvedSessionId
    }

}
