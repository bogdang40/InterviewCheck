import Foundation

struct KnowledgeContextBrief: Equatable {
    let text: String
    let factCount: Int
    let relationCount: Int
}

/// Renders retrieval results as a compact, citable block. Facts first, then
/// the relations among them, each on one line so the model can quote them.
final class KnowledgeContextComposer {
    struct Budget: Equatable {
        var totalCharacters = 2_600
        var maxFacts = 10
        var maxRelations = 12
        var summaryCharacters = 220

        static let `default` = Budget()
    }

    private let budget: Budget

    init(budget: Budget = .default) {
        self.budget = budget
    }

    func compose(_ result: KnowledgeRetrievalResult) -> KnowledgeContextBrief? {
        guard !result.isEmpty else { return nil }
        var lines: [String] = ["PERSONAL KNOWLEDGE GRAPH (facts about the candidate, use them when relevant):"]
        var remaining = budget.totalCharacters - lines[0].count
        var factCount = 0

        for hit in result.hits.prefix(budget.maxFacts) {
            let line = factLine(for: hit.node)
            guard remaining - line.count > 120 else { break }
            lines.append(line)
            remaining -= line.count
            factCount += 1
        }

        let labels = Dictionary(uniqueKeysWithValues: result.hits.map { ($0.node.id, $0.node.label) })
        var relationCount = 0
        let sortedEdges = result.edges.sorted { $0.weight > $1.weight }
        for edge in sortedEdges.prefix(budget.maxRelations) {
            guard let from = labels[edge.fromNodeID], let to = labels[edge.toNodeID] else { continue }
            var line = "  \(from) \(edge.relation.displayName) \(to)"
            if let evidence = edge.evidence?.trimmingCharacters(in: .whitespacesAndNewlines), !evidence.isEmpty {
                line += " (\(String(evidence.prefix(90))))"
            }
            guard remaining - line.count > 0 else { break }
            if relationCount == 0 { lines.append("Relations:") }
            lines.append(line)
            remaining -= line.count
            relationCount += 1
        }

        return KnowledgeContextBrief(text: lines.joined(separator: "\n"), factCount: factCount, relationCount: relationCount)
    }

    private func factLine(for node: KnowledgeNode) -> String {
        var line = "- [\(node.kind.displayName)] \(node.label)"
        if let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            line += ": \(String(summary.prefix(budget.summaryCharacters)))"
        }
        let details = node.properties.sorted { $0.key < $1.key }.prefix(3).map { "\($0.key)=\($0.value)" }
        if !details.isEmpty {
            line += " (\(details.joined(separator: ", ")))"
        }
        return line
    }
}
