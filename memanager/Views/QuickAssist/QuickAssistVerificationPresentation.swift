import Foundation

/// Display vocabulary for verification and tier so every surface (strip,
/// navigator, thread list) says the same thing in the same colour.
extension QuickAssistVerificationStatus {
    var displayLabel: String {
        switch self {
        case .pending: return "Pending"
        case .verified: return "Verified"
        case .needsReview: return "Needs review"
        case .failed: return "Failed"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .pending: return .neutral
        case .verified: return .success
        case .needsReview: return .warning
        case .failed: return .critical
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "clock.badge.questionmark"
        case .verified: return "checkmark.shield"
        case .needsReview: return "exclamationmark.shield"
        case .failed: return "xmark.shield"
        }
    }
}

extension QuickAssistModelTier {
    var badgeLabel: String {
        switch self {
        case .fast: return "FAST"
        case .deep: return "DEEP"
        }
    }

    var badgeTone: OverlayTone {
        switch self {
        case .fast: return .neutral
        case .deep: return .warning
        }
    }

    var helpText: String {
        switch self {
        case .fast: return "Fast tier: the provider's low latency model"
        case .deep: return "Deep tier: the provider's primary reasoning model"
        }
    }
}
