import Foundation

extension SessionLogger {
    // MARK: - Query Methods
    
    /// Get recent sessions for display
    func getRecentSessions(limit: Int = 50) -> [SessionRecord] {
        return database.getRecentSessions(limit: limit)
    }
    
    /// Get provider statistics
    func getProviderStats(days: Int = 30) -> [ProviderStatsRecord] {
        return database.getProviderStats(days: days)
    }
    
    /// Get API calls for a specific session
    func getAPICallsForSession(sessionId: String) -> [APICallRecord] {
        return database.getAPICallsForSession(sessionId: sessionId)
    }

    func loadSessionDebrief(sessionId: String) -> SessionDebrief? {
        database.loadSessionDebrief(sessionId: sessionId)
    }

    func saveSessionDebrief(_ debrief: SessionDebrief) {
        database.saveSessionDebrief(debrief)
    }

    func getTranscriptEntries(sessionId: String) -> [TranscriptEntryRecord] {
        database.getTranscriptEntries(sessionId: sessionId)
    }

    func getCoachFindings(sessionId: String) -> [CoachFindingRecord] {
        database.getCoachFindings(sessionId: sessionId)
    }

    func getSessionRecord(id: String) -> SessionRecord? {
        database.getSessionRecord(id: id)
    }

    func saveSessionSnapshot(_ snapshot: SessionSnapshotRecord) {
        database.saveSessionSnapshot(snapshot)
    }

    func loadSessionSnapshots(sessionId: String) -> [SessionSnapshotRecord] {
        database.loadSessionSnapshots(sessionId: sessionId)
    }

    func loadPracticeState() -> (cards: [PracticeCard], schedules: [PracticeSchedule], reviews: [PracticeReview]) {
        database.loadPracticeState()
    }

    func savePracticeCard(_ card: PracticeCard, schedule: PracticeSchedule) {
        database.upsertPracticeCard(card, schedule: schedule)
    }

    func savePracticeReview(_ review: PracticeReview, schedule: PracticeSchedule) throws {
        try database.insertPracticeReviewReporting(review, schedule: schedule)
    }

    func archivePracticeCard(cardID: String) {
        database.archivePracticeCard(cardID: cardID)
    }

    func clearPracticeData() {
        database.clearPracticeData()
    }

    // MARK: - Hub Memory

    func upsertMemoryNode(_ node: MemoryNodeRecord) {
        database.upsertMemoryNode(node)
    }

    func linkMemoryNodes(_ relationship: MemoryRelationshipRecord) {
        database.insertMemoryRelationship(relationship)
    }

    func searchHubMemory(query: String, limit: Int = 5) -> [MemorySearchHit] {
        database.searchMemoryNodes(query: query, limit: limit)
    }

    func searchHubMemory(query: RelatedMemoryQuery, limit: Int = 5) -> RelatedMemoryResult {
        database.searchRelatedMemory(query: query, limit: limit)
    }

    func clearHubMemory() throws {
        try database.clearHubMemory()
    }

    // MARK: - Workstream Timeline

    func getWorkstreamTimeline(filter: WorkstreamTimelineFilter) -> [WorkstreamTimelineEvent] {
        database.getWorkstreamTimeline(filter: filter)
    }

    // MARK: - Proactive Coach

    func upsertCoachFinding(_ finding: CoachFindingRecord) {
        database.upsertCoachFinding(finding)
    }

    func getActiveCoachFindings(
        sessionId: String? = nil,
        threadId: String? = nil,
        limit: Int = 20
    ) -> [CoachFindingRecord] {
        database.getActiveCoachFindings(sessionId: sessionId, threadId: threadId, limit: limit)
    }

    func updateCoachFindingStatus(
        id: String,
        status: CoachFindingStatus,
        dismissedAt: Date? = nil
    ) {
        database.updateCoachFindingStatus(id: id, status: status, dismissedAt: dismissedAt)
    }
    
}
