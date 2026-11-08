import Foundation

extension SessionController {
    /// Reset and opening the overlay prepare an in-memory draft. Persist only
    /// after real activity, including requests made without microphone capture.
    func beginSessionHistoryIfNeeded() {
        guard !logger.isLoggingSession(session.id) else { return }
        if logger.database.getSessionRecord(id: session.id.uuidString) != nil {
            logger.logSessionResumed(sessionId: session.id)
            return
        }
        session.startedAt = session.startedAt ?? Date()
        logger.logSessionStarted(
            session: session,
            provider: settings.selectedProvider.displayName,
            model: settings.selectedModel(for: settings.selectedProvider)
        )
        session.activeModeSnapshotID = SessionModeSnapshotWriter.shared.captureAtSessionStart(sessionID: session.id)
    }

    func persistManualScreenshots(_ screenshots: [Screenshot], capturedSessionID: UUID) {
        guard session.id == capturedSessionID else { return }
        session.screenshots = screenshots
        guard !screenshots.isEmpty else { return }
        beginSessionHistoryIfNeeded()
        logger.logSessionUpdated(session: session)
    }
}
