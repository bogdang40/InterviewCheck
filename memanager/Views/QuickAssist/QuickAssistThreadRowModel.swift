import Foundation

/// Relative timestamps for thread rows, without a dependency on the clock
/// so the wording can be tested.
enum QuickAssistRelativeTimeFormatter {
    static func string(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

/// Presentation facts for one thread row in the drawer.
struct QuickAssistThreadRowModel: Equatable {
    let summary: QuickAssistThreadSummary
    let metadata: ThreadCardMetadata?
    let isSelected: Bool
    let isActive: Bool
    let isPendingDeletion: Bool

    var isBranched: Bool {
        guard let parentID = summary.parentThreadId else { return false }
        return !parentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var verificationStatus: QuickAssistVerificationStatus? {
        metadata?.dominantVerificationStatus
    }

    var tier: QuickAssistModelTier? {
        metadata?.dominantModelTier
    }

    var coachingCount: Int {
        metadata?.coachFindingCount ?? 0
    }

    var preview: String? {
        guard let preview = summary.previewText?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty else {
            return nil
        }
        return preview
    }

    func relativeTime(now: Date = Date()) -> String {
        QuickAssistRelativeTimeFormatter.string(from: summary.lastTurnAt ?? summary.updatedAt, now: now)
    }
}
