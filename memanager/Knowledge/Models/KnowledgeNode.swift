import Foundation

/// Entity types in the personal knowledge graph. Deliberately small: these
/// are the nouns an interview conversation keeps returning to.
enum KnowledgeNodeKind: String, Codable, CaseIterable, Identifiable {
    case person
    case company
    case project
    case skill
    case story
    case problem
    case topic
    case role
    case document

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .person: return "Person"
        case .company: return "Company"
        case .project: return "Project"
        case .skill: return "Skill"
        case .story: return "Story"
        case .problem: return "Problem"
        case .topic: return "Topic"
        case .role: return "Role"
        case .document: return "Document"
        }
    }

    var systemImage: String {
        switch self {
        case .person: return "person"
        case .company: return "building.2"
        case .project: return "shippingbox"
        case .skill: return "wrench.and.screwdriver"
        case .story: return "text.book.closed"
        case .problem: return "exclamationmark.triangle"
        case .topic: return "tag"
        case .role: return "briefcase"
        case .document: return "doc"
        }
    }
}

/// Where a node or edge came from. Manual entries outrank extracted ones
/// when the two disagree.
enum KnowledgeSourceKind: String, Codable, CaseIterable {
    case manual
    case session
    case workspace

    var trust: Double {
        switch self {
        case .manual: return 1.0
        case .workspace: return 0.9
        case .session: return 0.75
        }
    }
}

struct KnowledgeNode: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var kind: KnowledgeNodeKind
    var label: String
    var summary: String?
    var properties: [String: String]
    var sourceKind: KnowledgeSourceKind
    var sourceRef: String?
    var workspaceID: UUID?
    var confidence: Double
    var mentionCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: KnowledgeNodeKind,
        label: String,
        summary: String? = nil,
        properties: [String: String] = [:],
        sourceKind: KnowledgeSourceKind = .manual,
        sourceRef: String? = nil,
        workspaceID: UUID? = nil,
        confidence: Double = 1.0,
        mentionCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.summary = summary
        self.properties = properties
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
        self.workspaceID = workspaceID
        self.confidence = confidence
        self.mentionCount = mentionCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Dedupe key: same kind plus same normalized label means the same entity.
    var normalizedLabel: String {
        KnowledgeNode.normalize(label)
    }

    /// Symbols that distinguish real skills ("C", "C++", "C#") survive.
    private static let retainedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#"))

    /// Locale independent so a machine in a Turkish locale produces the same
    /// key as an English one for the same label.
    static func normalize(_ label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let collapsed = folded
            .components(separatedBy: retainedCharacters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
