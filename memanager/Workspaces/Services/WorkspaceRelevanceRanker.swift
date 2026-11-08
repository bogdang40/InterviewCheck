import Foundation

/// Pure scoring used to pick which workspace documents and journal entries
/// earn a place in the prompt for a given question. No IO, fully testable.
enum WorkspaceRelevanceRanker {
    struct Scored<Item>: Equatable where Item: Equatable {
        let item: Item
        let score: Double
    }

    /// Ranking normalizes at most this much of each document. This runs on
    /// the main actor before every Quick Assist turn, so it must stay cheap;
    /// the excerpt step still reads the full text of the winners.
    static let rankingWindowCharacters = 6_000

    static func tokens(from text: String) -> Set<String> {
        Set(KnowledgeQueryTokenizer.tokens(from: text, maxTokens: 24))
    }

    /// Overlap between the question tokens and the text, scaled to (0, 1].
    static func overlapScore(questionTokens: Set<String>, text: String) -> Double {
        guard !questionTokens.isEmpty else { return 0 }
        let haystack = KnowledgeNode.normalize(text)
        guard !haystack.isEmpty else { return 0 }
        let matched = questionTokens.filter { haystack.contains($0) }.count
        return Double(matched) / Double(questionTokens.count)
    }

    static func rankDocuments(_ documents: [WorkspaceDocument], question: String) -> [Scored<WorkspaceDocument>] {
        let questionTokens = tokens(from: question)
        return documents
            .filter { $0.hasText && $0.category != .journal }
            .map { document in
                let window = String((document.extractedText ?? "").prefix(rankingWindowCharacters))
                let overlap = overlapScore(questionTokens: questionTokens, text: window + " " + document.fileName)
                let priorityBoost = 1.0 - Double(document.category.contextPriority) * 0.08
                return Scored(item: document, score: overlap * 0.7 + priorityBoost * 0.3)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.relativePath < rhs.item.relativePath
            }
    }

    static func rankJournal(_ entries: [WorkspaceJournalEntry], question: String, now: Date = Date()) -> [Scored<WorkspaceJournalEntry>] {
        let questionTokens = tokens(from: question)
        return entries
            .map { entry in
                let overlap = overlapScore(questionTokens: questionTokens, text: entry.title + " " + entry.body)
                let ageDays = max(0, now.timeIntervalSince(entry.createdAt) / 86_400)
                let recency = 1.0 / (1.0 + ageDays / 7.0)
                return Scored(item: entry, score: overlap * 0.6 + recency * 0.4)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.createdAt > rhs.item.createdAt
            }
    }

    /// Picks the most relevant window of `text` for the question: the
    /// paragraph with the highest overlap, padded with its neighbours.
    static func excerpt(from text: String, question: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let paragraphs = trimmed.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let questionTokens = tokens(from: question)
        guard !questionTokens.isEmpty, paragraphs.count > 1 else {
            return String(trimmed.prefix(maxCharacters)) + " ..."
        }
        let best = paragraphs.enumerated().max { lhs, rhs in
            overlapScore(questionTokens: questionTokens, text: lhs.element) < overlapScore(questionTokens: questionTokens, text: rhs.element)
        }?.offset ?? 0
        var window = paragraphs[best]
        var lower = best, upper = best
        while window.count < maxCharacters, lower > 0 || upper < paragraphs.count - 1 {
            if upper < paragraphs.count - 1 {
                upper += 1
                window += "\n\n" + paragraphs[upper]
            }
            if window.count < maxCharacters, lower > 0 {
                lower -= 1
                window = paragraphs[lower] + "\n\n" + window
            }
        }
        let prefix = lower > 0 ? "... " : ""
        let suffix = upper < paragraphs.count - 1 ? " ..." : ""
        return prefix + String(window.prefix(maxCharacters)) + suffix
    }
}
