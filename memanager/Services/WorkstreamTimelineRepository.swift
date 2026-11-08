import Foundation

protocol WorkstreamTimelineProviding {
    func loadTimeline(filter: WorkstreamTimelineFilter) -> [WorkstreamTimelineEvent]
    func loadActiveCoachFindings(sessionId: String?, threadId: String?, limit: Int) -> [CoachFindingRecord]
    func upsertCoachFinding(_ finding: CoachFindingRecord)
    func updateCoachFindingStatus(id: String, status: CoachFindingStatus, dismissedAt: Date?)
    func loadQuickAssistCalls(threadId: String) -> [QuickAssistCallRecord]
    func loadToolCalls(turnId: String) -> [SessionToolCallRecord]
    func loadQuickAssistThreads(limit: Int) -> [QuickAssistThreadSummary]
    func loadLatestQuickAssistThread(originSessionId: String) -> QuickAssistThreadSummary?
}

final class WorkstreamTimelineRepository: WorkstreamTimelineProviding {
    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func loadTimeline(filter: WorkstreamTimelineFilter) -> [WorkstreamTimelineEvent] {
        logger.getWorkstreamTimeline(filter: filter)
    }

    func loadActiveCoachFindings(
        sessionId: String?,
        threadId: String?,
        limit: Int
    ) -> [CoachFindingRecord] {
        logger.getActiveCoachFindings(sessionId: sessionId, threadId: threadId, limit: limit)
    }

    func upsertCoachFinding(_ finding: CoachFindingRecord) {
        logger.upsertCoachFinding(finding)
    }

    func updateCoachFindingStatus(
        id: String,
        status: CoachFindingStatus,
        dismissedAt: Date?
    ) {
        logger.updateCoachFindingStatus(id: id, status: status, dismissedAt: dismissedAt)
    }

    func loadQuickAssistCalls(threadId: String) -> [QuickAssistCallRecord] {
        logger.getQuickAssistCallsForThread(threadId: threadId, limit: 0)
    }

    func loadToolCalls(turnId: String) -> [SessionToolCallRecord] {
        logger.getToolCallsForTurn(turnId: turnId)
    }

    func loadQuickAssistThreads(limit: Int) -> [QuickAssistThreadSummary] {
        logger.getQuickAssistThreads(limit: limit)
    }

    func loadLatestQuickAssistThread(originSessionId: String) -> QuickAssistThreadSummary? {
        logger.getLatestQuickAssistThread(originSessionId: originSessionId)
    }
}
