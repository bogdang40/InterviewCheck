import Foundation

protocol SessionModeSnapshotAssetStoring {
    var rootDirectory: URL { get }
    func attachmentsDirectory(for snapshotID: UUID) throws -> URL
    func thumbnailsDirectory(for snapshotID: UUID) throws -> URL
    func fileURL(for attachment: ModeAttachment, snapshotID: UUID) -> URL?
    func snapshotAttachments(
        from mode: Mode,
        snapshotID: UUID,
        attachmentStorage: ModeAttachmentStoring
    ) -> [ModeAttachment]
}

final class SessionModeSnapshotAssetStorage: SessionModeSnapshotAssetStoring {
    static let shared = SessionModeSnapshotAssetStorage()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var rootDirectory: URL {
        if TestRuntime.isRunningUnitTests {
            return TestRuntime.temporaryDirectory.appendingPathComponent("session_mode_snapshots", isDirectory: true)
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("memanager/session_mode_snapshots", isDirectory: true)
    }

    func attachmentsDirectory(for snapshotID: UUID) throws -> URL {
        let url = rootDirectory
            .appendingPathComponent(snapshotID.uuidString, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func thumbnailsDirectory(for snapshotID: UUID) throws -> URL {
        let url = rootDirectory
            .appendingPathComponent(snapshotID.uuidString, isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func fileURL(for attachment: ModeAttachment, snapshotID: UUID) -> URL? {
        guard let directory = try? attachmentsDirectory(for: snapshotID) else { return nil }
        let url = directory.appendingPathComponent(attachment.storedFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func snapshotAttachments(
        from mode: Mode,
        snapshotID: UUID,
        attachmentStorage: ModeAttachmentStoring
    ) -> [ModeAttachment] {
        let sourceAttachmentsDirectory = try? attachmentStorage.attachmentsDirectory(for: mode.id)
        let destinationAttachmentsDirectory = try? attachmentsDirectory(for: snapshotID)
        let destinationThumbnailsDirectory = try? thumbnailsDirectory(for: snapshotID)

        return mode.attachments.map { attachment in
            if let sourceAttachmentsDirectory, let destinationAttachmentsDirectory {
                let sourceURL = sourceAttachmentsDirectory.appendingPathComponent(attachment.storedFilename)
                let destinationURL = destinationAttachmentsDirectory.appendingPathComponent(attachment.storedFilename)
                replaceItemIfNeeded(at: sourceURL, with: destinationURL)
            }

            var frozenAttachment = attachment
            if let thumbnailRelativePath = attachment.thumbnailRelativePath,
               let destinationThumbnailsDirectory {
                let sourceThumbnailURL = attachmentStorage.rootDirectory.appendingPathComponent(thumbnailRelativePath)
                let thumbnailName = URL(fileURLWithPath: thumbnailRelativePath).lastPathComponent
                let destinationThumbnailURL = destinationThumbnailsDirectory.appendingPathComponent(thumbnailName)
                replaceItemIfNeeded(at: sourceThumbnailURL, with: destinationThumbnailURL)
                if fileManager.fileExists(atPath: destinationThumbnailURL.path) {
                    frozenAttachment.thumbnailRelativePath = "\(snapshotID.uuidString)/thumbs/\(thumbnailName)"
                }
            }

            return frozenAttachment
        }
    }

    private func replaceItemIfNeeded(at sourceURL: URL, with destinationURL: URL) {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try? fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try? fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}

/// Captures the active Mode at session start and persists a `SessionModeSnapshotRecord`.
/// This decouples the session from later edits or deletions of the source Mode.
final class SessionModeSnapshotWriter {
    static let shared = SessionModeSnapshotWriter(
        database: SessionDatabase.shared,
        modeProvider: { ModeStoreBridge.activeMode() },
        attachmentStorage: FileSystemModeAttachmentStorage.shared,
        snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
    )

    private let database: SessionDatabase
    private let modeProvider: () -> Mode?
    private let attachmentStorage: ModeAttachmentStoring
    private let snapshotAssetStorage: SessionModeSnapshotAssetStoring

    init(
        database: SessionDatabase,
        modeProvider: @escaping () -> Mode?,
        attachmentStorage: ModeAttachmentStoring,
        snapshotAssetStorage: SessionModeSnapshotAssetStoring
    ) {
        self.database = database
        self.modeProvider = modeProvider
        self.attachmentStorage = attachmentStorage
        self.snapshotAssetStorage = snapshotAssetStorage
    }

    /// Captures the currently active Mode (if any) onto the session. Returns the snapshot ID if
    /// one was created, or nil when no Mode is active.
    @discardableResult
    func captureAtSessionStart(sessionID: UUID) -> UUID? {
        guard let mode = modeProvider() else { return nil }

        let snapshotID = UUID()
        let frozenAttachments = snapshotAssetStorage.snapshotAttachments(
            from: mode,
            snapshotID: snapshotID,
            attachmentStorage: attachmentStorage
        )
        let attachmentsPayload: Data = (try? JSONEncoder().encode(frozenAttachments)) ?? Data("[]".utf8)
        let attachmentsJSON = String(data: attachmentsPayload, encoding: .utf8) ?? "[]"

        let snapshot = SessionModeSnapshot(
            snapshotID: snapshotID,
            sessionID: sessionID,
            sourceModeID: mode.id,
            title: mode.title,
            promptText: mode.prompt,
            attachments: frozenAttachments,
            projectFolderDisplayPath: mode.projectFolder?.displayPath,
            projectFolderEnabledAtCapture: mode.projectFolder?.isEnabled ?? false
        )

        let record = SessionModeSnapshotRecord(
            snapshotID: snapshot.snapshotID.uuidString,
            sessionID: sessionID.uuidString,
            sourceModeID: mode.id.uuidString,
            capturedAt: snapshot.capturedAt,
            title: snapshot.title,
            promptText: snapshot.promptText,
            attachmentsJSON: attachmentsJSON,
            projectFolderDisplayPath: snapshot.projectFolderDisplayPath,
            projectFolderEnabledAtCapture: snapshot.projectFolderEnabledAtCapture,
            createdAt: Date()
        )
        database.saveSessionModeSnapshot(record)
        return snapshot.snapshotID
    }

    func loadSnapshot(sessionID: UUID) -> SessionModeSnapshot? {
        guard let record = database.loadSessionModeSnapshot(sessionID: sessionID.uuidString) else {
            return nil
        }
        return decodeSnapshot(from: record, fallbackSessionID: sessionID)
    }

    func loadSnapshot(snapshotID: UUID) -> SessionModeSnapshot? {
        guard let record = database.loadSessionModeSnapshot(snapshotID: snapshotID.uuidString) else {
            return nil
        }
        let sessionID = UUID(uuidString: record.sessionID) ?? UUID()
        return decodeSnapshot(from: record, fallbackSessionID: sessionID)
    }

    private func decodeSnapshot(
        from record: SessionModeSnapshotRecord,
        fallbackSessionID: UUID
    ) -> SessionModeSnapshot {
        let decoded: [ModeAttachment] = {
            guard let data = record.attachmentsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ModeAttachment].self, from: data)) ?? []
        }()
        let snapshotID = UUID(uuidString: record.snapshotID) ?? UUID()
        return SessionModeSnapshot(
            snapshotID: snapshotID,
            sessionID: UUID(uuidString: record.sessionID) ?? fallbackSessionID,
            sourceModeID: record.sourceModeID.flatMap { UUID(uuidString: $0) },
            capturedAt: record.capturedAt,
            title: record.title,
            promptText: record.promptText,
            attachments: decoded,
            projectFolderDisplayPath: record.projectFolderDisplayPath,
            projectFolderEnabledAtCapture: record.projectFolderEnabledAtCapture
        )
    }
}
