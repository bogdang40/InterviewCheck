import Foundation

struct HistoryBatchSelection: Equatable {
    var isSelecting = false
    var ids: Set<String> = []

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    mutating func retainEligible(_ eligibleIDs: Set<String>) {
        ids.formIntersection(eligibleIDs)
    }

    mutating func finish() {
        isSelecting = false
        ids = []
    }

    static func emptySession(_ session: SessionRecord, metadata: SessionCardMetadata?) -> Bool {
        !session.hasResponse && session.screenshotCount == 0 && session.transcriptWordCount == 0
            && (session.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && metadata?.totalTurns == 0 && metadata?.debriefPreview == nil && metadata?.hasCoachFindings == false
    }
}
