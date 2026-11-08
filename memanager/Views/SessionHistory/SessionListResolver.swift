import Foundation

/// Pure search, filter, and sort of the session list. The view holds one
/// value of this type as its state and asks it for the grouped rows.
struct SessionListResolver: Equatable {
    var query: String = ""
    var sortOrder: SessionSortOrder = .newest
    var filters: Set<SessionFilter> = []

    var isFiltering: Bool {
        !filters.isEmpty || !trimmedQuery.isEmpty
    }

    func groups(from sessions: [SessionRecord], metadata: [String: SessionCardMetadata]) -> [SessionDateGroup] {
        SessionDateGroup.group(sessions: apply(to: sessions, metadata: metadata))
    }

    func apply(to sessions: [SessionRecord], metadata: [String: SessionCardMetadata]) -> [SessionRecord] {
        sessions
            .filter { matches($0, metadata: metadata[$0.id]) }
            .sorted(by: comparator(metadata: metadata))
    }

    mutating func toggle(_ filter: SessionFilter) {
        if filters.contains(filter) {
            filters.remove(filter)
        } else {
            filters.insert(filter)
        }
    }

    static func selectionAfterDeleting(_ deletedID: String, selectedID: String?, visibleIDs: [String]) -> String? {
        selectionAfterDeleting([deletedID], selectedID: selectedID, visibleIDs: visibleIDs)
    }

    static func selectionAfterDeleting(_ deletedIDs: Set<String>, selectedID: String?, visibleIDs: [String]) -> String? {
        guard let selectedID, deletedIDs.contains(selectedID) else { return selectedID }
        guard let index = visibleIDs.firstIndex(of: selectedID) else { return nil }
        return visibleIDs.dropFirst(index + 1).first { !deletedIDs.contains($0) }
            ?? visibleIDs.prefix(index).last { !deletedIDs.contains($0) }
    }

    static func duration(of session: SessionRecord) -> TimeInterval {
        guard let end = session.endedAt else { return 0 }
        return end.timeIntervalSince(session.startedAt)
    }

    // MARK: Private

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ session: SessionRecord, metadata: SessionCardMetadata?) -> Bool {
        for filter in filters where !passes(filter, metadata: metadata) {
            return false
        }
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        let haystack = [session.provider, session.model, metadata?.debriefPreview, session.id]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return haystack.contains(needle)
    }

    private func passes(_ filter: SessionFilter, metadata: SessionCardMetadata?) -> Bool {
        switch filter {
        case .hasDebrief: return metadata?.debriefPreview != nil
        case .hasCoachFindings: return metadata?.hasCoachFindings == true
        case .highActivity: return (metadata?.totalTurns ?? 0) > 5
        }
    }

    private func comparator(metadata: [String: SessionCardMetadata]) -> (SessionRecord, SessionRecord) -> Bool {
        switch sortOrder {
        case .newest:
            return { $0.startedAt > $1.startedAt }
        case .oldest:
            return { $0.startedAt < $1.startedAt }
        case .byDuration:
            return { Self.duration(of: $0) > Self.duration(of: $1) }
        case .byThreadCount:
            return { (metadata[$0.id]?.threadCount ?? 0) > (metadata[$1.id]?.threadCount ?? 0) }
        }
    }
}
