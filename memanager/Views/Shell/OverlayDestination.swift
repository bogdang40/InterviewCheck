import Foundation

/// Primary navigation is independent from recording and the selected live task.
enum OverlayDestination: String, CaseIterable, Identifiable {
    case live, prepare, review, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    init(screen: OverlayScreen) {
        switch screen {
        case .mentor: self = .live
        case .workspaces, .knowledge, .practice: self = .prepare
        case .history: self = .review
        case .settings: self = .settings
        }
    }
}
