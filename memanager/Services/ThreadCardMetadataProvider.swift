import Foundation

protocol ThreadCardMetadataProviding {
    func computeMetadata(
        for threads: [QuickAssistThreadSummary]
    ) -> [String: ThreadCardMetadata]
}

final class ThreadCardMetadataProvider: ThreadCardMetadataProviding {
    private let repository: WorkstreamTimelineRepository

    init(repository: WorkstreamTimelineRepository = .init()) {
        self.repository = repository
    }

    func computeMetadata(
        for threads: [QuickAssistThreadSummary]
    ) -> [String: ThreadCardMetadata] {
        var map: [String: ThreadCardMetadata] = [:]

        for thread in threads {
            let calls = repository.loadQuickAssistCalls(threadId: thread.id)
            let findings = repository.loadActiveCoachFindings(
                sessionId: nil, threadId: thread.id, limit: 100
            )

            let verified = calls.filter { $0.verificationStatus == .verified }.count
            let needsReview = calls.filter { $0.verificationStatus == .needsReview }.count
            let failed = calls.filter { $0.verificationStatus == .failed }.count
            let pending = calls.filter { $0.verificationStatus == .pending }.count

            let tiers = calls.compactMap(\.modelTier)
            let deepCount = tiers.filter { $0 == .deep }.count
            let dominantTier: QuickAssistModelTier = deepCount > tiers.count / 2 ? .deep : .fast

            map[thread.id] = ThreadCardMetadata(
                id: thread.id,
                verifiedCount: verified,
                needsReviewCount: needsReview,
                failedCount: failed,
                pendingCount: pending,
                dominantModelTier: dominantTier,
                coachFindingCount: findings.count
            )
        }

        return map
    }
}
