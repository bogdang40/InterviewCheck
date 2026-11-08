import Foundation

extension SessionController {
    /// Loads metrics, skill report, and provider breakdown for the selected session.
    func loadSessionAnalytics(sessionID: String) {
        let requestID = reviewAnalyticsGate.begin(sessionID: sessionID)
        currentSessionMetrics = nil
        currentSkillReport = .empty
        currentProviderBreakdown = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let calls = self.logger.getQuickAssistCallsForSession(sessionId: sessionID, limit: 500)
            let findings = self.logger.getCoachFindings(sessionId: sessionID)
            let cardEvents = self.logger.getWorkstreamTimeline(
                filter: WorkstreamTimelineFilter(sessionId: sessionID, includeDebugEvents: true, limit: 120)
            ).filter { $0.type == .responseCard }

            let packager = DebriefEvidencePackager()
            let metrics = packager.computeMetrics(calls: calls, findings: findings, cardEvents: cardEvents)
            let skillReport = self.skillProgressionTracker.buildReport(currentSessionId: sessionID)
            let providerBreakdown = ProviderSessionSummary.from(calls: calls)

            DispatchQueue.main.async {
                guard self.reviewAnalyticsGate.accepts(requestID, sessionID: sessionID) else { return }
                self.currentSessionMetrics = metrics
                self.currentSkillReport = skillReport
                self.currentProviderBreakdown = providerBreakdown
            }
        }
    }
    /// Also called before fetching a replacement page, when its session IDs
    /// are not known yet, and before history deletion or session reset.
    func invalidateSessionCardMetadata() {
        sessionCardMetadataRequestID = UUID()
    }

    /// Pre-computes card metadata for a batch of sessions (thread count, verification stats, debrief preview).
    func loadSessionCardMetadata(
        sessions: [SessionRecord],
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        invalidateSessionCardMetadata()
        let requestID = sessionCardMetadataRequestID
        let threadSummaries = quickAssistThreadSummaries
        queue.async { [weak self, logger] in
            var map: [String: SessionCardMetadata] = [:]
            for session in sessions {
                let calls = logger.getQuickAssistCallsForSession(sessionId: session.id, limit: 200)
                let verified = calls.filter { $0.verificationStatus == .verified }.count
                let needsReview = calls.filter { $0.verificationStatus == .needsReview }.count
                let failed = calls.filter { $0.verificationStatus == .failed }.count
                let pending = calls.filter { $0.verificationStatus == .pending }.count
                let threadCount = threadSummaries.filter { $0.originSessionId == session.id }.count
                let tiers = calls.compactMap(\.modelTier)
                let deepCount = tiers.filter { $0 == .deep }.count
                let dominantTier: QuickAssistModelTier = deepCount > tiers.count / 2 ? .deep : .fast
                let debrief = logger.loadSessionDebrief(sessionId: session.id)
                let preview = debrief?.whatHappened.first
                let hasFindings = !logger.getCoachFindings(sessionId: session.id).isEmpty

                map[session.id] = SessionCardMetadata(
                    id: session.id,
                    verifiedCount: verified,
                    needsReviewCount: needsReview,
                    failedCount: failed,
                    pendingCount: pending,
                    threadCount: threadCount,
                    dominantTier: dominantTier,
                    debriefPreview: preview,
                    hasCoachFindings: hasFindings
                )
            }
            DispatchQueue.main.async {
                guard let self, self.sessionCardMetadataRequestID == requestID else { return }
                self.sessionCardMetadataMap = map
            }
        }
    }
    func invalidateThreadCardMetadata() {
        threadCardMetadataRequestID = UUID()
    }

    func refreshThreadCardMetadata(queue: DispatchQueue = .global(qos: .userInitiated)) {
        invalidateThreadCardMetadata()
        let requestID = threadCardMetadataRequestID
        let threads = quickAssistThreadSummaries
        let threadIDs = Set(threads.map(\.id))

        // Drop removed threads immediately, retain known metadata, and give
        // new rows a lightweight skeleton while their evidence is loading.
        var visibleMetadata = threadCardMetadataMap.filter { threadIDs.contains($0.key) }
        for thread in threads where visibleMetadata[thread.id] == nil {
            visibleMetadata[thread.id] = ThreadCardMetadata(
                id: thread.id,
                verifiedCount: 0,
                needsReviewCount: 0,
                failedCount: 0,
                pendingCount: thread.turnCount,
                dominantModelTier: .fast,
                coachFindingCount: 0
            )
        }
        if visibleMetadata != threadCardMetadataMap { threadCardMetadataMap = visibleMetadata }

        let provider = ThreadCardMetadataProvider(repository: WorkstreamTimelineRepository(logger: logger))
        queue.async { [weak self] in
            let map = provider.computeMetadata(for: threads)
            DispatchQueue.main.async {
                guard let self, self.threadCardMetadataRequestID == requestID else { return }
                self.threadCardMetadataMap = map
            }
        }
    }
}
