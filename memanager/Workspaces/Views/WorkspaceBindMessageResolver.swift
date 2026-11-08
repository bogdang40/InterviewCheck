import Foundation

/// What the user reads after handing a workspace folder to the active
/// Mode's tools.
struct WorkspaceBindMessage: Equatable {
    let text: String
    let tone: OverlayTone
}

enum WorkspaceBindMessageResolver {
    static func message(for result: WorkspaceQuickAssistBridge.BindResult) -> WorkspaceBindMessage {
        switch result {
        case .bound:
            return WorkspaceBindMessage(text: "The active Mode's read only tools now browse this folder.", tone: .success)
        case .noActiveMode:
            return WorkspaceBindMessage(text: "No active Mode to bind. Create one under Modes first.", tone: .warning)
        case .folderUnavailable:
            return WorkspaceBindMessage(text: "The folder could not be bookmarked. Check that it still exists.", tone: .critical)
        }
    }
}
