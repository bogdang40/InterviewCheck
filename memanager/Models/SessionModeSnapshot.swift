import Foundation

/// Frozen picture of the Mode that was active at session start. Attachments are denormalised
/// so the session remains fully reconstructable even if the source Mode is later edited or deleted.
struct SessionModeSnapshot: Codable, Equatable {
    let snapshotID: UUID
    let sessionID: UUID
    let sourceModeID: UUID?
    let capturedAt: Date
    var title: String
    var promptText: String
    var attachments: [ModeAttachment]
    var projectFolderDisplayPath: String?
    var projectFolderEnabledAtCapture: Bool

    init(
        snapshotID: UUID = UUID(),
        sessionID: UUID,
        sourceModeID: UUID?,
        capturedAt: Date = Date(),
        title: String,
        promptText: String,
        attachments: [ModeAttachment] = [],
        projectFolderDisplayPath: String? = nil,
        projectFolderEnabledAtCapture: Bool = false
    ) {
        self.snapshotID = snapshotID
        self.sessionID = sessionID
        self.sourceModeID = sourceModeID
        self.capturedAt = capturedAt
        self.title = title
        self.promptText = promptText
        self.attachments = attachments
        self.projectFolderDisplayPath = projectFolderDisplayPath
        self.projectFolderEnabledAtCapture = projectFolderEnabledAtCapture
    }

    /// Rehydrate into a transient read only `Mode` used during session resume when the source
    /// Mode no longer exists. Project folder access is not rehydrated (security bookmark lives
    /// on the live Mode, not the snapshot).
    func asEphemeralMode() -> Mode {
        Mode(
            id: sourceModeID ?? snapshotID,
            title: title,
            prompt: promptText,
            attachments: attachments,
            projectFolder: nil,
            createdAt: capturedAt,
            updatedAt: capturedAt
        )
    }
}
