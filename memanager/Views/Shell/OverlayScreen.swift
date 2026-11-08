import Foundation

/// Top level screens the stealth overlay can show. `mentor` is the live
/// interview surface (Assist, Solve, Design, Transcript); the others are
/// full screens that share the overlay so nothing about memanager is ever
/// visible to screen capture.
enum OverlayScreen: String, CaseIterable, Identifiable {
    case mentor
    case workspaces
    case knowledge
    case practice
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mentor: return "Mentor"
        case .workspaces: return "Workspaces"
        case .knowledge: return "Knowledge"
        case .practice: return "Practice"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .mentor: return "sparkles"
        case .workspaces: return "folder.badge.person.crop"
        case .knowledge: return "point.3.connected.trianglepath.dotted"
        case .practice: return "square.stack.3d.up"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    var help: String {
        switch self {
        case .mentor: return "Back to the interview surface"
        case .workspaces: return "Job Workspaces: one folder per role, injected into Quick Assist"
        case .knowledge: return "Personal Knowledge Graph: facts about you that Quick Assist can cite"
        case .practice: return "Practice: spaced repetition cards built from your sessions"
        case .history: return "History: past sessions, replay, and debriefs"
        case .settings: return "Settings (Cmd+U)"
        }
    }

    /// Screens offered in the command bar, in display order. `mentor` is
    /// reached by picking any surface instead.
    static let switchable: [OverlayScreen] = [.workspaces, .knowledge, .practice, .history, .settings]
}
