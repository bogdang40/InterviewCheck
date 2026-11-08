import Foundation

/// Rehydrates a past session back into the SessionController so the user can continue the
/// thread. Does not restart audio capture: the controller is left in `.paused` so the user
/// explicitly chooses whether to re enable the microphone.
protocol SessionResuming {
    func resumePayload(sessionID: UUID) -> ResumedSessionPayload?
}

struct ResumedSessionPayload {
    let sessionID: UUID
    let startedAt: Date?
    let transcript: String
    let transcriptEntries: [TranscriptEntry]
    let modeSnapshot: SessionModeSnapshot?
    let activeModeSnapshotID: UUID?
    let quickAssistThreadID: String?
}

final class SessionResumeService: SessionResuming {
    static let shared = SessionResumeService()

    private let snapshotWriter: SessionModeSnapshotWriter
    private let database: SessionDatabase
    private let logger: SessionLogger

    init(
        snapshotWriter: SessionModeSnapshotWriter = .shared,
        database: SessionDatabase = .shared,
        logger: SessionLogger = .shared
    ) {
        self.snapshotWriter = snapshotWriter
        self.database = database
        self.logger = logger
    }

    func resumePayload(sessionID: UUID) -> ResumedSessionPayload? {
        let sessionIDString = sessionID.uuidString
        guard let sessionRecord = logger.getSessionRecord(id: sessionIDString) else {
            return nil
        }
        let transcriptRecords = logger.getTranscriptEntries(sessionId: sessionIDString)
        let entries: [TranscriptEntry] = transcriptRecords.map { record in
            TranscriptEntry(
                speaker: mapSpeaker(rawValue: record.speaker),
                text: record.text,
                timestamp: record.timestamp,
                deepgramSpeakerId: nil
            )
        }
        let snapshot = snapshotWriter.loadSnapshot(sessionID: sessionID)

        return ResumedSessionPayload(
            sessionID: sessionID,
            startedAt: sessionRecord.startedAt,
            transcript: restoredTranscript(record: sessionRecord, entries: transcriptRecords),
            transcriptEntries: entries,
            modeSnapshot: snapshot,
            activeModeSnapshotID: snapshot?.snapshotID,
            quickAssistThreadID: logger.getLatestQuickAssistThread(originSessionId: sessionIDString)?.id
        )
    }

    private func restoredTranscript(record: SessionRecord, entries: [TranscriptEntryRecord]) -> String {
        if let transcript = record.transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript
        }
        return entries.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func mapSpeaker(rawValue: String) -> TranscriptSpeaker {
        switch rawValue.lowercased() {
        case "me":
            return .me
        case "unknown":
            return .unknown
        default:
            let digits = rawValue.filter { $0.isNumber }
            if let index = Int(digits) { return .speaker(index) }
            return .unknown
        }
    }
}

protocol SessionModeContextResolving {
    func composeContext(for session: Session, fallbackRealtimePrompt: String) -> ActiveModeContextComposer.Composed?
    func resolveToolMode(for session: Session) -> Mode?
}

final class SessionModeContextResolver: SessionModeContextResolving {
    static let shared = SessionModeContextResolver()

    private let snapshotWriter: SessionModeSnapshotWriter
    private let snapshotAssetStorage: SessionModeSnapshotAssetStoring
    private let activeModeProvider: () -> Mode?
    private let modeLookup: (UUID) -> Mode?

    init(
        snapshotWriter: SessionModeSnapshotWriter = .shared,
        snapshotAssetStorage: SessionModeSnapshotAssetStoring = SessionModeSnapshotAssetStorage.shared,
        activeModeProvider: @escaping () -> Mode? = { ModeStoreBridge.activeMode() },
        modeLookup: @escaping (UUID) -> Mode? = { ModeStoreBridge.mode(id: $0) }
    ) {
        self.snapshotWriter = snapshotWriter
        self.snapshotAssetStorage = snapshotAssetStorage
        self.activeModeProvider = activeModeProvider
        self.modeLookup = modeLookup
    }

    func composeContext(for session: Session, fallbackRealtimePrompt: String) -> ActiveModeContextComposer.Composed? {
        if let snapshot = resolvedSnapshot(for: session) {
            let source = ActiveModeContextComposer.Source(
                id: snapshot.sourceModeID,
                title: snapshot.title,
                promptText: snapshot.promptText,
                attachments: snapshot.attachments
            )
            return ActiveModeContextComposer.compose(
                fallbackRealtimePrompt: fallbackRealtimePrompt,
                source: source,
                attachmentFileResolver: { [snapshotAssetStorage] attachment in
                    snapshotAssetStorage.fileURL(for: attachment, snapshotID: snapshot.snapshotID)
                }
            )
        }

        return ActiveModeContextComposer.compose(
            fallbackRealtimePrompt: fallbackRealtimePrompt,
            mode: activeModeProvider()
        )
    }

    func resolveToolMode(for session: Session) -> Mode? {
        guard let snapshot = resolvedSnapshot(for: session) else {
            guard
                let liveMode = activeModeProvider(),
                let projectFolder = liveMode.projectFolder,
                projectFolder.isEnabled,
                projectFolder.bookmarkData != nil
            else {
                return nil
            }
            return liveMode
        }

        guard
            snapshot.projectFolderEnabledAtCapture,
            let sourceModeID = snapshot.sourceModeID,
            let liveMode = modeLookup(sourceModeID),
            let projectFolder = liveMode.projectFolder,
            projectFolder.isEnabled,
            projectFolder.bookmarkData != nil,
            normalizedPath(projectFolder.displayPath) == normalizedPath(snapshot.projectFolderDisplayPath)
        else {
            return nil
        }

        return liveMode
    }

    private func resolvedSnapshot(for session: Session) -> SessionModeSnapshot? {
        if let snapshotID = session.activeModeSnapshotID,
           let snapshot = snapshotWriter.loadSnapshot(snapshotID: snapshotID) {
            return snapshot
        }
        return snapshotWriter.loadSnapshot(sessionID: session.id)
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return (trimmed as NSString).standardizingPath
    }
}
