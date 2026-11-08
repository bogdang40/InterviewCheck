import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Coach Findings

    func upsertCoachFinding(_ finding: CoachFindingRecord) {
        performSync { db in
            guard let db else { return }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var existingID: String?
            let lookupSQL = """
            SELECT id
            FROM coach_findings
            WHERE dedupe_key = ? AND status = 'active'
            ORDER BY updated_at DESC
            LIMIT 1
            """
            var lookupStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, lookupSQL, -1, &lookupStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(lookupStmt, 1, finding.dedupeKey, -1, SQLITE_TRANSIENT)
                if sqlite3_step(lookupStmt) == SQLITE_ROW,
                   let idText = sqlite3_column_text(lookupStmt, 0) {
                    existingID = String(cString: idText)
                }
            }
            sqlite3_finalize(lookupStmt)

            if let existingID {
                let updateSQL = """
                UPDATE coach_findings
                SET session_id = ?,
                    thread_id = ?,
                    issue_type = ?,
                    severity = ?,
                    title = ?,
                    message = ?,
                    suggested_question = ?,
                    suggested_context = ?,
                    evidence_json = ?,
                    updated_at = ?,
                    dismissed_at = NULL
                WHERE id = ?
                """
                var updateStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                    bindOptionalText(finding.sessionId, at: 1, in: updateStmt)
                    bindOptionalText(finding.threadId, at: 2, in: updateStmt)
                    sqlite3_bind_text(updateStmt, 3, finding.issueType.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(updateStmt, 4, finding.severity.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(updateStmt, 5, finding.title, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(updateStmt, 6, finding.message, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(updateStmt, 7, finding.suggestedQuestion, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(updateStmt, 8, finding.suggestedContext, -1, SQLITE_TRANSIENT)
                    bindOptionalText(encodeCoachEvidence(finding.evidence), at: 9, in: updateStmt)
                    sqlite3_bind_int64(updateStmt, 10, nowMs)
                    sqlite3_bind_text(updateStmt, 11, existingID, -1, SQLITE_TRANSIENT)
                    sqlite3_step(updateStmt)
                }
                sqlite3_finalize(updateStmt)
                return
            }

            let insertSQL = """
            INSERT INTO coach_findings
            (id, session_id, thread_id, issue_type, severity, status, title, message,
             suggested_question, suggested_context, evidence_json, dedupe_key, created_at, updated_at, dismissed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, finding.id, -1, SQLITE_TRANSIENT)
                bindOptionalText(finding.sessionId, at: 2, in: insertStmt)
                bindOptionalText(finding.threadId, at: 3, in: insertStmt)
                sqlite3_bind_text(insertStmt, 4, finding.issueType.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 5, finding.severity.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 6, finding.status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 7, finding.title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 8, finding.message, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 9, finding.suggestedQuestion, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 10, finding.suggestedContext, -1, SQLITE_TRANSIENT)
                bindOptionalText(encodeCoachEvidence(finding.evidence), at: 11, in: insertStmt)
                sqlite3_bind_text(insertStmt, 12, finding.dedupeKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(insertStmt, 13, Int64(finding.createdAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(insertStmt, 14, Int64(finding.updatedAt.timeIntervalSince1970 * 1000))
                if let dismissedAt = finding.dismissedAt {
                    sqlite3_bind_int64(insertStmt, 15, Int64(dismissedAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(insertStmt, 15)
                }
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
        }
    }

    func getActiveCoachFindings(
        sessionId: String? = nil,
        threadId: String? = nil,
        limit: Int = 20
    ) -> [CoachFindingRecord] {
        var findings: [CoachFindingRecord] = []
        let normalizedLimit = max(1, min(limit, 200))

        performSync { db in
            guard let db else { return }

            var conditions: [String] = ["status = 'active'"]
            var bindValues: [String] = []
            if let sessionId, !sessionId.isEmpty {
                conditions.append("session_id = ?")
                bindValues.append(sessionId)
            }
            if let threadId, !threadId.isEmpty {
                conditions.append("thread_id = ?")
                bindValues.append(threadId)
            }

            let sql = """
            SELECT id, session_id, thread_id, issue_type, severity, status, title, message,
                   suggested_question, suggested_context, evidence_json, dedupe_key, created_at, updated_at, dismissed_at
            FROM coach_findings
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY
                CASE severity
                    WHEN 'critical' THEN 0
                    WHEN 'warning' THEN 1
                    ELSE 2
                END,
                updated_at DESC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (index, value) in bindValues.enumerated() {
                    sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
                }
                sqlite3_bind_int(stmt, Int32(bindValues.count + 1), Int32(normalizedLimit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    findings.append(makeCoachFindingRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }

        return findings
    }

    func updateCoachFindingStatus(
        id: String,
        status: CoachFindingStatus,
        dismissedAt: Date?
    ) {
        performSync { db in
            guard let db else { return }

            let sql = """
            UPDATE coach_findings
            SET status = ?, updated_at = ?, dismissed_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
                if let dismissedAt {
                    sqlite3_bind_int64(stmt, 3, Int64(dismissedAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_bind_text(stmt, 4, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func encodeCoachEvidence(_ evidence: [CoachEvidenceItem]) -> String? {
        guard !evidence.isEmpty,
              let data = try? JSONEncoder().encode(evidence) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeCoachEvidence(_ raw: String?) -> [CoachEvidenceItem] {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CoachEvidenceItem].self, from: data) else {
            return []
        }
        return decoded
    }

    func getCoachFindings(sessionId: String) -> [CoachFindingRecord] {
        var findings: [CoachFindingRecord] = []
        performSync { db in
            guard let db else { return }
            let sql = """
            SELECT id, session_id, thread_id, issue_type, severity, status, title, message,
                   suggested_question, suggested_context, evidence_json, dedupe_key, created_at, updated_at, dismissed_at
            FROM coach_findings
            WHERE session_id = ?
            ORDER BY updated_at DESC
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    findings.append(makeCoachFindingRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }
        return findings
    }

    private func makeCoachFindingRecord(from stmt: OpaquePointer?) -> CoachFindingRecord {
        let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
        let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let threadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let issueTypeRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? CoachIssueType.quickAssistFailureBurst.rawValue
        let severityRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? WorkstreamEventSeverity.warning.rawValue
        let statusRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? CoachFindingStatus.active.rawValue
        let title = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "Coach finding"
        let message = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
        let suggestedQuestion = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
        let suggestedContext = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let evidenceRaw = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let dedupeKey = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? issueTypeRaw
        let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 12)) / 1000)
        let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 13)) / 1000)
        let dismissedAt: Date? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 14)) / 1000)

        return CoachFindingRecord(
            id: id,
            sessionId: sessionId,
            threadId: threadId,
            issueType: CoachIssueType(rawValue: issueTypeRaw) ?? .quickAssistFailureBurst,
            severity: WorkstreamEventSeverity(rawValue: severityRaw) ?? .warning,
            status: CoachFindingStatus(rawValue: statusRaw) ?? .active,
            title: title,
            message: message,
            suggestedQuestion: suggestedQuestion,
            suggestedContext: suggestedContext,
            evidence: decodeCoachEvidence(evidenceRaw),
            dedupeKey: dedupeKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            dismissedAt: dismissedAt
        )
    }
}
