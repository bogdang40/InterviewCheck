import Foundation

extension Notification.Name {
    static let sessionSummaryDidChange = Notification.Name("memanager.sessionSummaryDidChange")
}

enum SessionSummaryNotificationUserInfo {
    static let sessionID = "sessionID"
    static let status = "status"
}

protocol SessionSummaryComposing {
    func generate(sessionID: UUID) async
    func loadCached(sessionID: UUID) -> SessionSummary?
}

/// Orchestrates end of session summary generation. One shot LLM call, tolerant JSON parse,
/// heuristic fallback if the call or parse fails. Persists to SQLite via `SessionDatabase`.
final class SessionSummaryComposer: SessionSummaryComposing {
    static let shared = SessionSummaryComposer()

    private let database: SessionDatabase
    private let snapshotWriter: SessionModeSnapshotWriter
    private let llmClient: SessionSummaryLLMCalling
    private let settings: SettingsManager

    init(
        database: SessionDatabase = .shared,
        snapshotWriter: SessionModeSnapshotWriter = .shared,
        llmClient: SessionSummaryLLMCalling = SessionSummaryLLMClient.shared,
        settings: SettingsManager = .shared
    ) {
        self.database = database
        self.snapshotWriter = snapshotWriter
        self.llmClient = llmClient
        self.settings = settings
    }

    func loadCached(sessionID: UUID) -> SessionSummary? {
        guard let (record, items) = database.loadSessionSummary(sessionID: sessionID.uuidString) else {
            return nil
        }
        let actionItems = items.map { item in
            SessionSummary.ActionItem(
                id: UUID(uuidString: item.id) ?? UUID(),
                title: item.title,
                owner: item.owner,
                dueDate: item.dueDate,
                notes: item.notes
            )
        }
        let status = SessionSummary.Status(rawValue: record.status) ?? .pending
        return SessionSummary(
            sessionID: sessionID,
            status: status,
            actionItems: actionItems,
            backgroundSummary: record.backgroundSummary,
            followUpEmailDraft: record.followUpEmail,
            generatedAt: record.generatedAt,
            errorMessage: record.errorMessage
        )
    }

    func generate(sessionID: UUID) async {
        // A reset can leave an unsaved draft, and history can be deleted
        // before a detached end-of-session generation task starts.
        guard let session = database.getSessionRecord(id: sessionID.uuidString) else { return }
        if let existing = loadCached(sessionID: sessionID),
           existing.status == .completed {
            return
        }

        persistStatus(.generating, sessionID: sessionID)

        let transcript = SessionSummaryTranscript(
            savedText: session.transcript,
            entries: database.getTranscriptEntries(sessionId: sessionID.uuidString)
        )
        let snapshot = snapshotWriter.loadSnapshot(sessionID: sessionID)
        let prompts = SessionSummaryPromptBuilder.build(
            sessionID: sessionID,
            transcript: transcript,
            modeSnapshot: snapshot
        )

        do {
            let raw = try await llmClient.send(
                systemPrompt: prompts.system,
                userPrompt: prompts.user,
                settings: settings
            )
            let payload = try SessionSummaryJSONParser.parse(rawResponse: raw)
            let summary = SessionSummaryJSONParser.makeSummary(sessionID: sessionID, from: payload)
            persist(summary)
        } catch {
            let fallback = heuristicFallback(
                sessionID: sessionID,
                transcript: transcript,
                snapshot: snapshot,
                errorMessage: error.localizedDescription
            )
            persist(fallback)
        }
    }

    // MARK: - Persistence

    private func persistStatus(_ status: SessionSummary.Status, sessionID: UUID) {
        let existing = loadCached(sessionID: sessionID)
        let record = SessionSummaryRecord(
            sessionID: sessionID.uuidString,
            status: status.rawValue,
            backgroundSummary: existing?.backgroundSummary ?? "",
            followUpEmail: existing?.followUpEmailDraft,
            generatedAt: existing?.generatedAt,
            errorMessage: existing?.errorMessage,
            createdAt: Date(),
            updatedAt: Date()
        )
        database.saveSessionSummary(record, actionItems: [])
        notifySummaryChanged(sessionID: sessionID, status: status)
    }

    private func persist(_ summary: SessionSummary) {
        let record = SessionSummaryRecord(
            sessionID: summary.sessionID.uuidString,
            status: summary.status.rawValue,
            backgroundSummary: summary.backgroundSummary,
            followUpEmail: summary.followUpEmailDraft,
            generatedAt: summary.generatedAt,
            errorMessage: summary.errorMessage,
            createdAt: Date(),
            updatedAt: Date()
        )
        let actionItems = summary.actionItems.enumerated().map { index, item in
            SessionSummaryActionItemRecord(
                id: item.id.uuidString,
                sessionID: summary.sessionID.uuidString,
                title: item.title,
                owner: item.owner,
                dueDate: item.dueDate,
                notes: item.notes,
                ordinal: index,
                createdAt: Date()
            )
        }
        database.saveSessionSummary(record, actionItems: actionItems)
        notifySummaryChanged(sessionID: summary.sessionID, status: summary.status)
    }

    // MARK: - Heuristic fallback

    private func heuristicFallback(
        sessionID: UUID,
        transcript: SessionSummaryTranscript,
        snapshot: SessionModeSnapshot?,
        errorMessage: String
    ) -> SessionSummary {
        var lines: [String] = []
        if let snapshot {
            lines.append("Active mode: \(snapshot.title).")
        }
        lines.append(contentsOf: transcript.fallbackLines)
        let summary = lines.joined(separator: "\n")
        return SessionSummary(
            sessionID: sessionID,
            status: .heuristic,
            actionItems: [],
            backgroundSummary: summary,
            followUpEmailDraft: nil,
            generatedAt: Date(),
            errorMessage: errorMessage
        )
    }

    private func notifySummaryChanged(sessionID: UUID, status: SessionSummary.Status) {
        NotificationCenter.default.post(
            name: .sessionSummaryDidChange,
            object: nil,
            userInfo: [
                SessionSummaryNotificationUserInfo.sessionID: sessionID.uuidString,
                SessionSummaryNotificationUserInfo.status: status.rawValue
            ]
        )
    }
}
