import Foundation
import SQLite3

extension SessionDatabase {
    func executeFTSCandidateSearch(
        db: OpaquePointer,
        matchQuery: String,
        limit: Int,
        weight: Double,
        reason: RelatedMemoryReason,
        candidates: inout [String: MemorySearchCandidate]
    ) {
        let sql = """
        SELECT n.id, n.session_id, n.source_type, n.source_ref, n.content, n.summary, n.tags,
               n.importance, n.created_at, n.updated_at, n.thread_id, n.turn_id, n.question_source, n.intent, n.context_mode,
               bm25(memory_nodes_fts)
        FROM memory_nodes_fts
        JOIN memory_nodes n ON n.id = memory_nodes_fts.node_id
        WHERE memory_nodes_fts MATCH ?
        ORDER BY bm25(memory_nodes_fts), n.importance DESC, n.updated_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, matchQuery, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let node = makeMemoryNodeRecord(from: stmt)
                let bm25Score = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? 0.0 : sqlite3_column_double(stmt, 15)
                let lexical = (1 - exp(-abs(bm25Score) / 20.0)) * weight
                mergeMemoryCandidate(
                    node: node,
                    lexical: lexical,
                    relationship: 0,
                    reason: reason,
                    relationType: nil,
                    into: &candidates
                )
            }
        }
        sqlite3_finalize(stmt)
    }

    func executeTokenOverlapSearch(
        db: OpaquePointer,
        tokens: [String],
        limit: Int,
        candidates: inout [String: MemorySearchCandidate]
    ) {
        let sql = """
        SELECT id, session_id, source_type, source_ref, content, summary, tags, importance, created_at, updated_at, thread_id, turn_id, question_source, intent, context_mode
        FROM memory_nodes
        ORDER BY updated_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let node = makeMemoryNodeRecord(from: stmt)
                let searchable = [
                    node.summary ?? "",
                    String(node.content.prefix(600)),
                    node.tags.joined(separator: " ")
                ]
                    .joined(separator: " ")
                    .lowercased()
                if searchable.isEmpty { continue }

                let overlap = tokens.reduce(into: 0) { count, token in
                    if searchable.contains(token) {
                        count += 1
                    }
                }
                guard overlap > 0 else { continue }

                let lexical = (Double(overlap) / Double(max(tokens.count, 1))) * 0.85
                mergeMemoryCandidate(
                    node: node,
                    lexical: lexical,
                    relationship: 0,
                    reason: .lexicalExpansion,
                    relationType: nil,
                    into: &candidates
                )
            }
        }
        sqlite3_finalize(stmt)
    }

    func applyRelationshipExpansion(
        db: OpaquePointer,
        maxHops: Int,
        candidates: inout [String: MemorySearchCandidate]
    ) {
        guard maxHops > 0, !candidates.isEmpty else { return }

        var frontier = Set(
            candidates.values
                .sorted { $0.lexicalScore > $1.lexicalScore }
                .prefix(6)
                .map { $0.node.id }
        )
        var visited = frontier

        for _ in 0..<maxHops {
            guard !frontier.isEmpty else { break }
            var nextFrontier = Set<String>()

            for seedId in frontier {
                let sql = """
                SELECT from_node_id, to_node_id, relation_type, strength
                FROM memory_relationships
                WHERE from_node_id = ? OR to_node_id = ?
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, seedId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, seedId, -1, SQLITE_TRANSIENT)

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let fromId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                        let toId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                        let relationRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? MemoryRelationType.supportsAnswer.rawValue
                        let strength = Int(sqlite3_column_int(stmt, 3))
                        guard !fromId.isEmpty, !toId.isEmpty else { continue }

                        let neighborId = fromId == seedId ? toId : fromId
                        guard !neighborId.isEmpty else { continue }

                        let relationType = MemoryRelationType(rawValue: relationRaw)
                        let normalizedStrength = min(1.0, Double(max(1, strength)) / 3.0)
                        let relationScore = 0.12 * normalizedStrength

                        if let existing = candidates[neighborId] {
                            var updated = existing
                            updated.relationshipScore = max(updated.relationshipScore, relationScore)
                            updated.reasons.insert(.relationshipHop)
                            if updated.relationType == nil {
                                updated.relationType = relationType
                            }
                            candidates[neighborId] = updated
                        } else if let node = fetchMemoryNode(id: neighborId, db: db) {
                            mergeMemoryCandidate(
                                node: node,
                                lexical: 0.04,
                                relationship: relationScore,
                                reason: .relationshipHop,
                                relationType: relationType,
                                into: &candidates
                            )
                        }

                        if !visited.contains(neighborId) {
                            nextFrontier.insert(neighborId)
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }

            visited.formUnion(nextFrontier)
            frontier = nextFrontier
        }
    }

    private func mergeMemoryCandidate(
        node: MemoryNodeRecord,
        lexical: Double,
        relationship: Double,
        reason: RelatedMemoryReason,
        relationType: MemoryRelationType?,
        into candidates: inout [String: MemorySearchCandidate]
    ) {
        if var existing = candidates[node.id] {
            existing.lexicalScore = max(existing.lexicalScore, lexical)
            existing.relationshipScore = max(existing.relationshipScore, relationship)
            existing.reasons.insert(reason)
            if existing.relationType == nil {
                existing.relationType = relationType
            }
            candidates[node.id] = existing
            return
        }

        candidates[node.id] = MemorySearchCandidate(
            node: node,
            lexicalScore: max(0, lexical),
            relationshipScore: max(0, relationship),
            reasons: [reason],
            relationType: relationType,
            threadScore: 0,
            questionSourceScore: 0,
            intentScore: 0,
            contextModeScore: 0,
            recencyScore: 0,
            importanceScore: 0
        )
    }

    private func fetchMemoryNode(id: String, db: OpaquePointer) -> MemoryNodeRecord? {
        let sql = """
        SELECT id, session_id, source_type, source_ref, content, summary, tags, importance, created_at, updated_at, thread_id, turn_id, question_source, intent, context_mode
        FROM memory_nodes
        WHERE id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        var node: MemoryNodeRecord?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                node = makeMemoryNodeRecord(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return node
    }

}
