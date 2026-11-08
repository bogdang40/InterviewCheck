import Foundation

/// How a fact reads in the list and the detail header: its tone by kind,
/// its one line subtitle, and where it came from.
enum KnowledgeNodePresentation {
    static func tone(for kind: KnowledgeNodeKind) -> OverlayTone {
        switch kind {
        case .story, .project: return .info
        case .skill: return .success
        case .problem: return .warning
        case .person, .company, .topic, .role, .document: return .neutral
        }
    }

    /// Falls back to the kind when a node carries no summary yet.
    static func subtitle(for node: KnowledgeNode) -> String {
        guard let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return node.kind.displayName
        }
        return summary
    }

    static func sourceLine(for node: KnowledgeNode) -> String {
        switch node.sourceKind {
        case .manual: return node.sourceRef?.hasPrefix("paste:") == true ? "Extracted from pasted text" : "Added by hand"
        case .session: return "Learned from a session"
        case .workspace: return "Extracted from a workspace"
        }
    }

    static func mentionLine(count: Int) -> String {
        count == 1 ? "Mentioned once" : "Mentioned \(count) times"
    }
}
