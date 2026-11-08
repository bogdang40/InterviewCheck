import Foundation

struct ThreadCardMetadata: Identifiable, Equatable {
    let id: String
    let verifiedCount: Int
    let needsReviewCount: Int
    let failedCount: Int
    let pendingCount: Int
    let dominantModelTier: QuickAssistModelTier
    let coachFindingCount: Int

    var totalTurns: Int {
        verifiedCount + needsReviewCount + failedCount + pendingCount
    }

    var verifiedFraction: Double {
        totalTurns > 0 ? Double(verifiedCount) / Double(totalTurns) : 0
    }

    var dominantVerificationStatus: QuickAssistVerificationStatus {
        if failedCount > 0 { return .failed }
        if needsReviewCount > 0 { return .needsReview }
        if verifiedCount > 0 { return .verified }
        return .pending
    }
}
