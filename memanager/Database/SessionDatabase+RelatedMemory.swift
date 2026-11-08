import Foundation
import SQLite3

extension SessionDatabase {

    struct MemorySearchCandidate {
        var node: MemoryNodeRecord
        var lexicalScore: Double
        var relationshipScore: Double
        var reasons: Set<RelatedMemoryReason>
        var relationType: MemoryRelationType?
        var threadScore: Double
        var questionSourceScore: Double
        var intentScore: Double
        var contextModeScore: Double
        var recencyScore: Double
        var importanceScore: Double

        var finalScore: Double {
            lexicalScore +
                relationshipScore +
                threadScore +
                questionSourceScore +
                intentScore +
                contextModeScore +
                recencyScore +
                importanceScore
        }
    }

    func searchRelatedMemory(query: RelatedMemoryQuery, limit: Int = 5) -> RelatedMemoryResult {
        let startedAt = Date()
        let normalizedLimit = max(1, min(limit, 24))
        let trimmedQuery = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = relatedMemoryTokens(from: trimmedQuery)

        if trimmedQuery.isEmpty || tokens.isEmpty {
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let result = RelatedMemoryResult(
                snippets: [],
                queryTokens: tokens,
                confidence: 0,
                latencyMs: latencyMs,
                diagnostics: "empty_query"
            )
            insertMemoryRetrievalEvent(
                MemoryRetrievalEventRecord(
                    querySource: query.querySource,
                    queryText: trimmedQuery,
                    queryTokens: tokens,
                    anchorQuery: nil,
                    expansionQuery: nil,
                    hitCount: 0,
                    topNodeIds: [],
                    topScore: 0,
                    confidence: 0,
                    latencyMs: latencyMs,
                    sessionId: query.sessionId,
                    threadId: query.threadId,
                    turnId: query.turnId
                )
            )
            return result
        }

        var anchorQuery: String?
        var expansionQuery: String?
        var snippets: [RelatedMemorySnippet] = []
        var confidence = 0.0

        performSync { db in
            guard let db else { return }

            var candidates: [String: MemorySearchCandidate] = [:]
            if memoryFTSSupported {
                let anchorTokens = Array(tokens.prefix(min(6, tokens.count)))
                if !anchorTokens.isEmpty {
                    anchorQuery = makeFTSMatchQuery(tokens: anchorTokens, useAnd: true)
                    if let anchorQuery, !anchorQuery.isEmpty {
                        executeFTSCandidateSearch(
                            db: db,
                            matchQuery: anchorQuery,
                            limit: query.anchorLimit,
                            weight: 1.0,
                            reason: .lexicalAnchor,
                            candidates: &candidates
                        )
                    }
                }

                let expansionTokens = Array(tokens.prefix(min(14, tokens.count)))
                if !expansionTokens.isEmpty {
                    expansionQuery = makeFTSMatchQuery(tokens: expansionTokens, useAnd: false)
                    if let expansionQuery, !expansionQuery.isEmpty {
                        executeFTSCandidateSearch(
                            db: db,
                            matchQuery: expansionQuery,
                            limit: query.expansionLimit,
                            weight: 0.72,
                            reason: .lexicalExpansion,
                            candidates: &candidates
                        )
                    }
                }
            }

            if candidates.count < max(8, normalizedLimit * 2) {
                executeTokenOverlapSearch(
                    db: db,
                    tokens: tokens,
                    limit: max(160, normalizedLimit * 20),
                    candidates: &candidates
                )
            }

            if query.maxGraphHops > 0, !candidates.isEmpty {
                applyRelationshipExpansion(
                    db: db,
                    maxHops: query.maxGraphHops,
                    candidates: &candidates
                )
            }

            let now = Date()
            for id in candidates.keys {
                guard var candidate = candidates[id] else { continue }

                if let queryThread = query.threadId,
                   let nodeThread = candidate.node.threadId,
                   !queryThread.isEmpty,
                   queryThread == nodeThread {
                    candidate.threadScore = max(candidate.threadScore, 0.16)
                    candidate.reasons.insert(.threadMatch)
                }

                if let querySource = query.questionSource,
                   let nodeSource = candidate.node.questionSource,
                   querySource == nodeSource {
                    candidate.questionSourceScore = max(candidate.questionSourceScore, 0.07)
                    candidate.reasons.insert(.questionSourceMatch)
                }

                if let queryIntent = query.intent,
                   let nodeIntent = candidate.node.intent,
                   queryIntent.rawValue == nodeIntent {
                    candidate.intentScore = max(candidate.intentScore, 0.06)
                    candidate.reasons.insert(.intentMatch)
                }

                if let queryMode = query.contextMode,
                   let nodeMode = candidate.node.contextMode,
                   queryMode.rawValue == nodeMode {
                    candidate.contextModeScore = max(candidate.contextModeScore, 0.06)
                    candidate.reasons.insert(.contextModeMatch)
                }

                let ageDays = now.timeIntervalSince(candidate.node.updatedAt) / 86_400
                let recency = max(0, 1 - min(1, ageDays / 28.0)) * 0.11
                if recency > 0 {
                    candidate.recencyScore = recency
                    candidate.reasons.insert(.recencyBoost)
                }

                let importance = max(0, min(candidate.node.importance, 3))
                let importanceBoost = (Double(importance) / 3.0) * 0.08
                if importanceBoost > 0 {
                    candidate.importanceScore = importanceBoost
                    candidate.reasons.insert(.importanceBoost)
                }

                candidates[id] = candidate
            }

            let excludedIDs = Set(query.excludedNodeIds)
            var seenNormalizedText = Set<String>()
            let orderedCandidates = candidates.values.sorted {
                if $0.finalScore == $1.finalScore {
                    return $0.node.updatedAt > $1.node.updatedAt
                }
                return $0.finalScore > $1.finalScore
            }

            for candidate in orderedCandidates {
                guard !excludedIDs.contains(candidate.node.id) else { continue }
                let snippetText = memorySnippetText(for: candidate.node)
                guard !snippetText.isEmpty else { continue }

                let dedupeKey = normalizeMemoryTextForDedupe(snippetText)
                guard !seenNormalizedText.contains(dedupeKey) else { continue }
                seenNormalizedText.insert(dedupeKey)

                snippets.append(RelatedMemorySnippet(
                    id: candidate.node.id,
                    text: snippetText,
                    sourceType: candidate.node.sourceType,
                    sourceRef: candidate.node.sourceRef,
                    threadId: candidate.node.threadId,
                    turnId: candidate.node.turnId,
                    score: candidate.finalScore,
                    reasons: candidate.reasons.sorted { $0.rawValue < $1.rawValue },
                    relationType: candidate.relationType,
                    isPinned: false
                ))

                if snippets.count >= normalizedLimit {
                    break
                }
            }

            confidence = snippets.first?.score ?? 0
            if confidence < 0.35 {
                snippets = []
                confidence = 0
            }
        }

        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let diagnostics = "tokens=\(tokens.count), hits=\(snippets.count), confidence=\(String(format: "%.2f", confidence))"
        let result = RelatedMemoryResult(
            snippets: snippets,
            queryTokens: tokens,
            confidence: confidence,
            latencyMs: latencyMs,
            diagnostics: diagnostics
        )
        insertMemoryRetrievalEvent(
            MemoryRetrievalEventRecord(
                querySource: query.querySource,
                queryText: trimmedQuery,
                queryTokens: tokens,
                anchorQuery: anchorQuery,
                expansionQuery: expansionQuery,
                hitCount: snippets.count,
                topNodeIds: snippets.prefix(5).map(\.id),
                topScore: snippets.first?.score ?? 0,
                confidence: confidence,
                latencyMs: latencyMs,
                sessionId: query.sessionId,
                threadId: query.threadId,
                turnId: query.turnId
            )
        )
        return result
    }

    private func memorySnippetText(for node: MemoryNodeRecord) -> String {
        if let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return String(summary.prefix(240))
        }
        let content = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(content.prefix(240))
    }

    private func normalizeMemoryTextForDedupe(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .prefix(140)
            .description
    }

    private func relatedMemoryTokens(from query: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "that", "with", "from", "this", "have", "there", "then", "your",
            "about", "into", "were", "been", "only", "their", "they", "them", "would", "could",
            "should", "what", "when", "where", "which", "while", "most", "also", "just", "very",
            "screen", "latest", "single", "infer", "answer", "question", "continue", "selected"
        ]
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
            .filter { !stopwords.contains($0) }
        var seen = Set<String>()
        var deduped: [String] = []
        for token in tokens where !seen.contains(token) {
            seen.insert(token)
            deduped.append(token)
            if deduped.count >= 24 { break }
        }
        return deduped
    }

}
