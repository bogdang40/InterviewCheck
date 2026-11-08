import SwiftUI

/// Renders the full screen chosen in the command bar. The mentor surface is
/// composed by `MentorStage`, so this host only knows the other screens.
struct OverlayScreenHost: View {
    let screen: OverlayScreen

    var body: some View {
        switch screen {
        case .mentor:
            EmptyView()
        case .workspaces:
            WorkspacesScreen()
        case .knowledge:
            KnowledgeScreen()
        case .practice:
            PracticeStudioView()
        case .history:
            SessionHistoryView()
        case .settings:
            SettingsScreen()
        }
    }
}
