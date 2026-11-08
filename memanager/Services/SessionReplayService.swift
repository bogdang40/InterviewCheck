import Foundation

protocol SessionReplayLoading {
    func load(sessionID: String) -> SessionReplay
}

final class SessionReplayService: SessionReplayLoading {
    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func load(sessionID: String) -> SessionReplay {
        let session = logger.getSessionRecord(id: sessionID)
        let transcriptEntries = logger.getTranscriptEntries(sessionId: sessionID)
        let snapshots = logger.loadSessionSnapshots(sessionId: sessionID).map { record in
            SessionReplaySnapshot(
                record: record,
                image: SessionSnapshotCipher.decryptSnapshot(record)
            )
        }
        let calls = logger.getQuickAssistCallsForSession(sessionId: sessionID, limit: 500)
            .sorted { $0.startedAt < $1.startedAt }
        let turns = calls.map { call in
            SessionReplayTurnEvidence(
                call: call,
                toolCalls: logger.getToolCallsForTurn(turnId: call.turnId)
            )
        }
        let filter = WorkstreamTimelineFilter(
            sessionId: sessionID,
            threadId: nil,
            searchQuery: "",
            includeDebugEvents: true,
            enabledEventTypes: nil,
            limit: 1000
        )
        let events = logger.getWorkstreamTimeline(filter: filter)
            .sorted { $0.timestamp < $1.timestamp }
        let findings = logger.getCoachFindings(sessionId: sessionID)
            .sorted { $0.updatedAt < $1.updatedAt }
        let practiceCards = logger.loadPracticeState().cards
            .filter { $0.sessionID == sessionID }
            .sorted { $0.createdAt < $1.createdAt }

        return SessionReplay(
            session: session,
            events: events,
            snapshots: snapshots,
            turns: turns,
            transcriptEntries: transcriptEntries,
            coachFindings: findings,
            debrief: logger.loadSessionDebrief(sessionId: sessionID),
            practiceCards: practiceCards
        )
    }
}
