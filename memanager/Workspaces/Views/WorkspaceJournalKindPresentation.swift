import Foundation

/// Semantic tone for each journal entry kind: solved work reads as
/// success, rounds as information, open questions as something to close.
enum WorkspaceJournalKindPresentation {
    static func tone(for kind: WorkspaceJournalKind) -> OverlayTone {
        switch kind {
        case .problemSolved: return .success
        case .interviewRound: return .info
        case .question: return .warning
        case .decision, .note: return .neutral
        }
    }
}
