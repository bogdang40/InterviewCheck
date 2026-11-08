import Foundation

enum SidebarThreadFilter: String, CaseIterable, Identifiable, Hashable {
    case verified = "Verified"
    case needsReview = "Needs Review"
    case hasCoaching = "Coaching"
    case branched = "Branched"

    var id: String { rawValue }

    static func apply(
        filters: Set<SidebarThreadFilter>,
        to summaries: [QuickAssistThreadSummary],
        metadataMap: [String: ThreadCardMetadata]
    ) -> [QuickAssistThreadSummary] {
        guard !filters.isEmpty else { return summaries }
        return summaries.filter { summary in
            guard let meta = metadataMap[summary.id] else { return false }
            for filter in filters {
                switch filter {
                case .verified:
                    if meta.dominantVerificationStatus != .verified { return false }
                case .needsReview:
                    if meta.needsReviewCount == 0 { return false }
                case .hasCoaching:
                    if meta.coachFindingCount == 0 { return false }
                case .branched:
                    let isBranched = summary.parentThreadId.map {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    } ?? false
                    if !isBranched { return false }
                }
            }
            return true
        }
    }
}
