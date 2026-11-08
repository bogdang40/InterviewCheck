import Foundation

extension SessionLogger {
    /// Get recent Quick Assist calls across sessions
    func getRecentQuickAssistCalls(limit: Int = 200) -> [QuickAssistCallRecord] {
        return database.getRecentQuickAssistCalls(limit: limit)
    }

    /// Get Quick Assist calls for a specific session
    func getQuickAssistCallsForSession(sessionId: String, limit: Int = 100) -> [QuickAssistCallRecord] {
        return database.getQuickAssistCallsForSession(sessionId: sessionId, limit: limit)
    }

    /// Get Quick Assist calls for a specific thread
    /// Single turn fetch, avoiding a whole-thread load for one record.
    func getQuickAssistCall(threadId: String, turnId: String) -> QuickAssistCallRecord? {
        database.getQuickAssistCall(threadId: threadId, turnId: turnId)
    }

    func getQuickAssistCallsForThread(threadId: String, limit: Int = 0) -> [QuickAssistCallRecord] {
        return database.getQuickAssistCallsForThread(threadId: threadId, limit: limit)
    }

    func getToolCallsForTurn(turnId: String) -> [SessionToolCallRecord] {
        database.loadToolCalls(turnID: turnId)
    }

    /// Get all Quick Assist threads
    func getQuickAssistThreads(limit: Int = 200) -> [QuickAssistThreadSummary] {
        return database.getQuickAssistThreads(limit: limit)
    }

    func getLatestQuickAssistThread(originSessionId: String) -> QuickAssistThreadSummary? {
        return database.getLatestQuickAssistThread(originSessionId: originSessionId)
    }

    /// Store a copied call in the same database as its branch metadata.
    func logQuickAssistCall(_ record: QuickAssistCallRecord) {
        database.insertQuickAssistCall(record)
    }

    /// Create a new Quick Assist thread if it doesn't exist
    func createQuickAssistThread(
        threadId: String,
        title: String? = nil,
        originSessionId: String? = nil,
        parentThreadId: String? = nil,
        branchedFromTurnId: String? = nil,
        selectedMode: QuickAssistThreadMode = .auto
    ) {
        database.createQuickAssistThread(
            threadId: threadId,
            title: title,
            originSessionId: originSessionId,
            parentThreadId: parentThreadId,
            branchedFromTurnId: branchedFromTurnId,
            selectedMode: selectedMode
        )
    }

    func updateQuickAssistThreadSelectedMode(
        threadId: String,
        selectedMode: QuickAssistThreadMode
    ) {
        database.updateQuickAssistThreadSelectedMode(
            threadId: threadId,
            selectedMode: selectedMode
        )
    }

    /// Delete a Quick Assist thread and all of its turns
    func deleteQuickAssistThread(threadId: String) {
        database.deleteQuickAssistThread(threadId: threadId)
    }

    func logQuickAssistPolicyEvent(_ event: QuickAssistPolicyEventRecord) {
        database.insertQuickAssistPolicyEvent(event)
    }

    func updateQuickAssistCallVerification(
        threadId: String,
        turnId: String,
        verification: QuickAssistVerificationRecord
    ) {
        database.updateQuickAssistCallVerification(
            threadId: threadId,
            turnId: turnId,
            verification: verification
        )
    }

    func updateQuickAssistCallFeedback(
        threadId: String,
        turnId: String,
        status: QuickAssistTurnFeedbackStatus,
        note: String?,
        feedbackAt: Date = Date()
    ) {
        database.updateQuickAssistCallFeedback(
            threadId: threadId,
            turnId: turnId,
            status: status,
            note: note,
            feedbackAt: feedbackAt
        )
    }

    func logResponseCardEvent(
        name: String,
        sessionId: String,
        momentId: String,
        card: ResponseCard,
        details: String? = nil
    ) {
        let baseDetails = [
            "session_id=\(sessionId)",
            "moment_id=\(momentId)",
            "card_id=\(card.id)",
            "type=\(card.type.rawValue)",
            "action=\(card.recommendedAction.rawValue)",
            details
        ]
        .compactMap { $0 }
        .joined(separator: ", ")

        let event = DebugEventRecord(
            sessionId: sessionId,
            eventType: "response_card",
            eventCategory: "response_card",
            eventName: name,
            details: baseDetails,
            stackTrace: nil,
            threadInfo: DebugEventRecord.currentThreadInfo(),
            memoryUsageMB: nil
        )
        database.insertDebugEvent(event)
    }

    func createQuickAssistExperiment(
        id: String,
        sessionId: String,
        sourceThreadId: String,
        sourceTurnId: String,
        selectedIntent: QuickAssistIntent?,
        routeConfidence: Double?,
        status: QuickAssistExperimentStatus
    ) {
        database.insertQuickAssistExperiment(
            id: id,
            sessionId: sessionId,
            sourceThreadId: sourceThreadId,
            sourceTurnId: sourceTurnId,
            selectedIntent: selectedIntent,
            routeConfidence: routeConfidence,
            status: status
        )
    }

    func updateQuickAssistExperiment(
        id: String,
        status: QuickAssistExperimentStatus,
        winnerCandidateId: String?
    ) {
        database.updateQuickAssistExperiment(
            id: id,
            status: status,
            winnerCandidateId: winnerCandidateId
        )
    }

    func loadQuickAssistExperiment(id: String) -> QuickAssistExperiment? {
        database.loadQuickAssistExperiment(id: id)
    }

    func getQuickAssistThreadPins(threadId: String) -> Set<String> {
        database.getQuickAssistThreadPins(threadId: threadId)
    }

    func setQuickAssistThreadPin(
        threadId: String,
        memoryNodeId: String,
        pinned: Bool
    ) {
        database.setQuickAssistThreadPin(
            threadId: threadId,
            memoryNodeId: memoryNodeId,
            pinned: pinned
        )
    }

}
