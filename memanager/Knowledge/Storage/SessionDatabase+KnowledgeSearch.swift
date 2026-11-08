import Foundation
import SQLite3

extension SessionDatabase {
    /// The node columns qualified with the alias the FTS join uses.
    private static let joinedKnowledgeNodeColumns: String = SessionDatabase.knowledgeNodeColumns
        .split(separator: ",")
        .map { "n.\($0.trimmingCharacters(in: .whitespaces))" }
        .joined(separator: ", ")

    /// Lexical seed search. FTS5 with bm25 when available, otherwise a LIKE
    /// scan scored by how many query tokens the label and summary contain.
    func searchKnowledgeNodes(text: String, limit: Int = 10) -> [KnowledgeSearchHit] {
        let tokens = KnowledgeQueryTokenizer.tokens(from: text)
        guard !tokens.isEmpty else { return [] }
        let cappedLimit = max(1, min(limit, 50))
        let split = KnowledgeQueryTokenizer.splitForFTS(tokens)
        return (try? performSyncThrowing { db in
            var hits: [KnowledgeSearchHit] = []
            if knowledgeFTSSupported, let match = KnowledgeQueryTokenizer.ftsMatchQuery(tokens: split.fts) {
                hits = try searchKnowledgeNodesFTS(db: db, match: match, limit: cappedLimit)
            }
            if !split.symbolic.isEmpty {
                let exact = try searchKnowledgeNodesLike(db: db, tokens: split.symbolic, limit: cappedLimit)
                hits = KnowledgeSeedScoring.merge(hits, exact, limit: cappedLimit)
            }
            if !hits.isEmpty { return hits }
            return try searchKnowledgeNodesLike(db: db, tokens: tokens, limit: cappedLimit)
        }) ?? []
    }

    private func searchKnowledgeNodesFTS(db: OpaquePointer, match: String, limit: Int) throws -> [KnowledgeSearchHit] {
        let sql = """
        SELECT \(Self.joinedKnowledgeNodeColumns),
               bm25(kg_nodes_fts) AS rank
        FROM kg_nodes_fts
        JOIN kg_nodes n ON n.id = kg_nodes_fts.node_id
        WHERE kg_nodes_fts MATCH ?
        ORDER BY rank, n.mention_count DESC, n.updated_at DESC
        LIMIT ?
        """
        let statement = try SQLiteStatement(db: db, sql: sql)
        statement.bindText(match, at: 1)
        statement.bindInt(limit, at: 2)
        var ordered: [KnowledgeNode] = []
        while try statement.stepRow() {
            if let node = makeKnowledgeNode(from: statement) { ordered.append(node) }
        }
        return KnowledgeSeedScoring.scores(forOrdered: ordered)
    }

    private func searchKnowledgeNodesLike(db: OpaquePointer, tokens: [String], limit: Int) throws -> [KnowledgeSearchHit] {
        let clauses = tokens.map { _ in "(normalized_label LIKE ? OR LOWER(COALESCE(summary, '')) LIKE ?)" }
        let sql = """
        SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes
        WHERE \(clauses.joined(separator: " OR "))
        ORDER BY mention_count DESC, updated_at DESC
        LIMIT ?
        """
        let statement = try SQLiteStatement(db: db, sql: sql)
        var index: Int32 = 1
        for token in tokens {
            statement.bindText("%\(token)%", at: index)
            statement.bindText("%\(token)%", at: index + 1)
            index += 2
        }
        statement.bindInt(limit * 3, at: index)
        var hits: [KnowledgeSearchHit] = []
        while try statement.stepRow() {
            guard let node = makeKnowledgeNode(from: statement) else { continue }
            let haystack = (node.normalizedLabel + " " + (node.summary ?? "").lowercased())
            let matched = tokens.filter { haystack.contains($0) }.count
            let score = Double(matched) / Double(tokens.count)
            hits.append(KnowledgeSearchHit(node: node, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}

/// bm25 magnitudes depend on corpus size (a four node graph yields values
/// near one millionth), so the seed score is derived from the rank order the
/// database already produced: the best hit gets 1.0 and the last hit 0.5.
enum KnowledgeSeedScoring {
    static func scores(forOrdered nodes: [KnowledgeNode]) -> [KnowledgeSearchHit] {
        guard nodes.count > 1 else { return nodes.map { KnowledgeSearchHit(node: $0, score: 1.0) } }
        let step = 0.5 / Double(nodes.count - 1)
        return nodes.enumerated().map { offset, node in
            KnowledgeSearchHit(node: node, score: 1.0 - step * Double(offset))
        }
    }

    /// Unions two hit lists by node, keeping the higher score, best first.
    static func merge(_ lhs: [KnowledgeSearchHit], _ rhs: [KnowledgeSearchHit], limit: Int) -> [KnowledgeSearchHit] {
        var best: [UUID: KnowledgeSearchHit] = [:]
        for hit in lhs + rhs {
            if let current = best[hit.node.id], current.score >= hit.score { continue }
            best[hit.node.id] = hit
        }
        return Array(best.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.node.mentionCount > rhs.node.mentionCount
        }.prefix(limit))
    }
}

/// Query normalization shared by FTS and LIKE paths. Pure so it is testable.
enum KnowledgeQueryTokenizer {
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "what", "how", "about", "tell", "your",
        "you", "have", "from", "was", "were", "are", "did", "does", "can", "could", "would",
        "should", "when", "where", "which", "there", "their", "into", "onto", "over", "under",
        "please", "just", "like", "some", "them", "then", "than", "been", "being", "will", "our",
        "an", "as", "at", "be", "by", "do", "if", "in", "is", "it", "me", "my", "no", "of", "on",
        "or", "so", "to", "up", "us", "we", "am", "he", "she", "his", "her", "its", "not", "but"
    ]

    static func tokens(from text: String, maxTokens: Int = 12) -> [String] {
        let normalized = KnowledgeNode.normalize(text)
        var seen = Set<String>()
        var result: [String] = []
        for token in normalized.split(separator: " ") {
            let value = String(token)
            // Two character tokens matter here: Go, C#, R, AI, ML, QA.
            guard value.count >= 2, !stopWords.contains(value), !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value)
            if result.count >= maxTokens { break }
        }
        return result
    }

    /// Prefix match on every token joined with OR: "stripe"* OR "payment"*
    static func ftsMatchQuery(tokens: [String]) -> String? {
        let safe = tokens.map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !safe.isEmpty else { return nil }
        return safe.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    /// The porter tokenizer behind kg_nodes_fts drops `#` and `+`, so "c#"
    /// would match as the prefix "c". Those tokens are answered by the LIKE
    /// scan instead and the rest go to FTS.
    static func splitForFTS(_ tokens: [String]) -> (fts: [String], symbolic: [String]) {
        let symbolic = tokens.filter { $0.contains("#") || $0.contains("+") }
        let fts = tokens.filter { !$0.contains("#") && !$0.contains("+") }
        return (fts, symbolic)
    }
}
