import Foundation

/// Primary navigation is independent from recording and the selected live task.
enum OverlayDestination: String, CaseIterable, Identifiable {
    case live, prepare, review, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Interview"
        case .prepare: return "Roles"
        case .review: return "Reports"
        case .settings: return "Settings"
        }
    }

    /// The line above the content pane.
    var heading: String {
        switch self {
        case .live: return "Interview"
        case .prepare: return "Roles and interview kits"
        case .review: return "Interview reports"
        case .settings: return "Settings"
        }
    }

    init(screen: OverlayScreen) {
        switch screen {
        case .mentor: self = .live
        case .workspaces, .knowledge, .practice: self = .prepare
        case .history: self = .review
        case .settings: self = .settings
        }
    }
}
