import Foundation

/// Prompt contract for turning free text into graph entries. The model is
/// asked for strict JSON using the exact kind and relation vocabularies the
/// app persists, so parsing never needs fuzzy mapping.
enum KnowledgeExtractionPrompt {
    static let systemPrompt: String = {
        let kinds = KnowledgeNodeKind.allCases.map(\.rawValue).joined(separator: ", ")
        let relations = KnowledgeRelation.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You maintain a personal knowledge graph for a software engineer preparing for interviews.
        Extract durable facts about the candidate from the provided text: people they worked with,
        companies, projects, skills, stories with outcomes, problems they solved, and topics.

        Return ONLY a JSON object with this exact shape and nothing else:
        {"nodes":[{"kind":"<kind>","label":"<short canonical name>","summary":"<one sentence, optional>"}],
         "edges":[{"from":"<node label>","to":"<node label>","relation":"<relation>","evidence":"<short quote, optional>"}]}

        Allowed kinds: \(kinds)
        Allowed relations: \(relations)

        Rules:
        - Use "Me" as the label for the candidate (kind person).
        - Keep labels short and canonical (company names without suffixes, skills as nouns).
        - Skip generic filler; extract at most 12 nodes and 16 edges.
        - Every edge endpoint must appear in nodes.
        - Never invent facts that the text does not support.
        """
    }()

    static func userPrompt(text: String, workspaceTitle: String?) -> String {
        var sections: [String] = []
        if let workspaceTitle, !workspaceTitle.isEmpty {
            sections.append("Context: this text comes from work on the job pursuit \"\(workspaceTitle)\".")
        }
        sections.append("Text:\n\(String(text.prefix(12_000)))")
        return sections.joined(separator: "\n\n")
    }
}

/// Decoded extraction payload, before it is merged into the graph.
struct ExtractedKnowledge: Equatable {
    struct Node: Equatable {
        let kind: KnowledgeNodeKind
        let label: String
        let summary: String?
    }

    struct Edge: Equatable {
        let from: String
        let to: String
        let relation: KnowledgeRelation
        let evidence: String?
    }

    var nodes: [Node]
    var edges: [Edge]

    static let empty = ExtractedKnowledge(nodes: [], edges: [])
    var isEmpty: Bool { nodes.isEmpty }
}

/// Tolerant parser: strips code fences, ignores unknown kinds or relations,
/// drops edges whose endpoints are missing, and dedupes by normalized label.
enum KnowledgeExtractionParser {
    private struct Payload: Decodable {
        struct RawNode: Decodable { let kind: String?; let label: String?; let summary: String? }
        struct RawEdge: Decodable { let from: String?; let to: String?; let relation: String?; let evidence: String? }
        let nodes: [RawNode]?
        let edges: [RawEdge]?
    }

    static func parse(_ raw: String) -> ExtractedKnowledge {
        guard let json = extractJSONObject(from: raw), let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .empty
        }
        // Edges reference labels only, so one label maps to exactly one node:
        // the first kind the model used for it wins.
        var seen = Set<String>()
        var nodes: [ExtractedKnowledge.Node] = []
        for rawNode in payload.nodes ?? [] {
            guard let kind = rawNode.kind.flatMap(KnowledgeNodeKind.init(rawValue:)),
                  let label = rawNode.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
            let key = KnowledgeNode.normalize(label)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let summary = rawNode.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            nodes.append(.init(kind: kind, label: label, summary: (summary?.isEmpty ?? true) ? nil : summary))
        }
        let labels = Set(nodes.map { KnowledgeNode.normalize($0.label) })
        var edges: [ExtractedKnowledge.Edge] = []
        for rawEdge in payload.edges ?? [] {
            guard let from = rawEdge.from?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let to = rawEdge.to?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let relation = rawEdge.relation.flatMap(KnowledgeRelation.init(rawValue:)),
                  labels.contains(KnowledgeNode.normalize(from)), labels.contains(KnowledgeNode.normalize(to)),
                  KnowledgeNode.normalize(from) != KnowledgeNode.normalize(to) else { continue }
            let evidence = rawEdge.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            edges.append(.init(from: from, to: to, relation: relation, evidence: (evidence?.isEmpty ?? true) ? nil : evidence))
        }
        return ExtractedKnowledge(nodes: nodes, edges: edges)
    }

    /// Finds the outermost {...} in a response that may carry fences or prose.
    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return String(raw[start...end])
    }
}
