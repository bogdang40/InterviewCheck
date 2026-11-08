import Foundation

/// The one seam between Job Workspaces and the Quick Assist pipeline.
/// SessionController asks it for a context block before a turn and hands it
/// the finished turn afterwards; everything else about workspaces stays out
/// of the controller.
@MainActor
final class WorkspaceQuickAssistBridge {
    static let shared = WorkspaceQuickAssistBridge()

    enum BindResult: Equatable {
        case bound
        case noActiveMode
        case folderUnavailable
    }

    private let store: WorkspaceStore
    private let composer: WorkspaceContextComposer
    private let recorder: WorkspaceJournalRecorder
    private let settings: SettingsManager

    init(
        store: WorkspaceStore? = nil,
        composer: WorkspaceContextComposer = WorkspaceContextComposer(),
        recorder: WorkspaceJournalRecorder = WorkspaceJournalRecorder(),
        settings: SettingsManager = .shared
    ) {
        self.store = store ?? .shared
        self.composer = composer
        self.recorder = recorder
        self.settings = settings
    }

    /// The workspace whose brief goes into the prompt. Nil while context
    /// injection is switched off.
    var activeWorkspace: JobWorkspace? {
        guard settings.workspaceContextEnabled else { return nil }
        return store.activeWorkspace
    }

    /// The workspace a turn belongs to for journaling and graph attribution,
    /// independent of whether its brief is injected. Turning the context
    /// toggle off must not silently stop the journal.
    var currentWorkspace: JobWorkspace? {
        store.activeWorkspace
    }

    /// Prompt block for the active workspace, or empty when there is none.
    func contextBlock(question: String) -> String {
        guard let workspace = activeWorkspace else { return "" }
        return composer.compose(workspace: workspace, question: question).text
    }

    /// Appends a problem solved entry to the workspace the turn ran with,
    /// which the caller captured before the request, so switching the pill
    /// mid turn never journals into the wrong folder.
    func recordProblemSolved(workspaceID: UUID?, question: String, response: String, sessionID: String?, threadID: String?, turnID: String?) {
        guard settings.workspaceJournalAutoRecordEnabled, let workspaceID, let workspace = store.workspace(id: workspaceID) else { return }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 80 else { return }
        recorder.recordProblemSolved(
            workspace: workspace,
            question: question,
            response: trimmed,
            sessionID: sessionID,
            threadID: threadID,
            turnID: turnID
        )
        store.noteJournalChanged(for: workspace.id)
    }

    /// Points the active Mode's read only tool sandbox at the workspace
    /// folder so the existing tool loop can browse it. A fresh bookmark is
    /// preferred so a folder renamed in Finder still resolves.
    @discardableResult
    func bindFolderToActiveModeTools(_ workspace: JobWorkspace, modeStore: ModeStore? = nil) -> BindResult {
        let modeStore = modeStore ?? .shared
        guard let mode = modeStore.activeMode else { return .noActiveMode }
        guard let bookmark = WorkspaceStore.bookmark(for: workspace.folderURL) ?? workspace.folderBookmark else { return .folderUnavailable }
        var config = mode.projectFolder ?? ProjectFolderConfig()
        config.isEnabled = true
        config.bookmarkData = bookmark
        config.displayPath = workspace.folderPath
        config.rootName = workspace.folderURL.lastPathComponent
        modeStore.setProjectFolder(config, modeID: mode.id)
        return .bound
    }
}
