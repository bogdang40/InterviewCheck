import Foundation

struct ReviewSessionPage {
    let sessions: [SessionRecord]
    let totalCount: Int
    let emptyCount: Int
    let emptySessionIDs: Set<String>
}

extension SessionDatabase {
    /// Legacy session metadata can be empty even when child tables contain
    /// recorded work. Mode snapshots and debug events alone are setup, not activity.
    private static let reviewHistoryCTE = """
        WITH activity AS (
            SELECT session_id FROM api_calls
            UNION SELECT session_id FROM quick_assist_calls
            UNION SELECT session_id FROM transcript_entries WHERE length(trim(text)) > 0
            UNION SELECT session_id FROM screenshots
            UNION SELECT session_id FROM session_snapshots
            UNION SELECT session_id FROM session_debriefs
            UNION SELECT session_id FROM session_summaries
            UNION SELECT session_id FROM session_summary_action_items
            UNION SELECT session_id FROM session_tool_calls
            UNION SELECT session_id FROM memory_nodes
            UNION SELECT session_id FROM coach_findings
            UNION SELECT session_id FROM quick_assist_experiments
            UNION SELECT session_id FROM practice_cards
            UNION SELECT session_id FROM workspace_journal
        ), history AS (
            SELECT s.*, (s.has_response != 0 OR s.screenshot_count > 0
                OR s.transcript_word_count > 0
                OR length(trim(coalesce(s.transcript, ''), char(9) || char(10) || char(13) || ' ')) > 0
                OR s.state IN ('listening', 'paused')
                OR s.id IN (SELECT session_id FROM activity WHERE session_id IS NOT NULL)) AS has_activity
            FROM sessions s
        )
        """

    func getReviewSessions(limit: Int = 120, includeEmpty: Bool = false) throws -> ReviewSessionPage {
        try performSyncThrowing { db in
            let counts = try SQLiteStatement(db: db, sql: Self.reviewHistoryCTE + """
                SELECT count(*), coalesce(sum(NOT has_activity), 0) FROM history
                """)
            _ = try counts.stepRow()
            let storedCount = counts.columnInt(0)
            let emptyCount = counts.columnInt(1)
            let query = try SQLiteStatement(db: db, sql: Self.reviewHistoryCTE + """
                SELECT id, started_at, ended_at, state, transcript, transcript_word_count,
                       max(screenshot_count, (SELECT count(*) FROM screenshots WHERE session_id = history.id)),
                       has_response OR EXISTS (SELECT 1 FROM api_calls WHERE session_id = history.id AND status = 'success'),
                       provider, model, has_activity,
                       (SELECT group_concat(text, char(10)) FROM
                           (SELECT text FROM transcript_entries WHERE session_id = history.id ORDER BY timestamp))
                FROM history WHERE has_activity OR ?1
                ORDER BY started_at DESC, id DESC LIMIT ?2
                """)
            query.bindBool(includeEmpty, at: 1)
            query.bindInt(max(1, min(limit, 100_000)), at: 2)
            var sessions: [SessionRecord] = []
            var emptyIDs: Set<String> = []
            while try query.stepRow() {
                guard let id = query.columnText(0), let state = query.columnText(3) else { continue }
                let parentTranscript = query.columnText(4)
                let transcript = (parentTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    ? query.columnText(11) : parentTranscript
                let wordCount = transcript?.split(whereSeparator: \.isWhitespace).count ?? 0
                sessions.append(SessionRecord(
                    id: id, startedAt: query.columnDate(1), endedAt: query.columnOptionalDate(2),
                    state: state, transcript: transcript, transcriptWordCount: max(wordCount, query.columnInt(5)),
                    screenshotCount: query.columnInt(6), hasResponse: query.columnBool(7),
                    provider: query.columnText(8), model: query.columnText(9)
                ))
                if !query.columnBool(10) { emptyIDs.insert(id) }
            }
            return ReviewSessionPage(sessions: sessions, totalCount: includeEmpty ? storedCount : storedCount - emptyCount,
                                     emptyCount: emptyCount, emptySessionIDs: emptyIDs)
        }
    }
}
