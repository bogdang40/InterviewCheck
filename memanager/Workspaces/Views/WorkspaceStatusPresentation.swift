import Foundation

/// Maps a workspace stage onto the semantic tone its badge and list row
/// use, so the hot pipeline stands out and closed ones recede.
enum WorkspaceStatusPresentation {
    /// How far a row fades once its workspace is archived.
    static let archivedOpacity: Double = 0.5

    static func tone(for status: JobWorkspaceStatus) -> OverlayTone {
        switch status {
        case .interviewing: return .info
        case .offer: return .success
        case .applied, .researching, .closed: return .neutral
        }
    }

    /// Subtitle for a list row: archived overrides the role line.
    static func subtitle(for workspace: JobWorkspace) -> String {
        workspace.isArchived ? "Archived" : workspace.subtitle
    }

    static func rowOpacity(isArchived: Bool) -> Double {
        isArchived ? archivedOpacity : 1
    }
}
