import Foundation

// MARK: - TimelineDisplayItem

/// A display-ready item for the timeline lane: either a single event
/// or a time-windowed cluster of events collapsed into one node.
enum TimelineDisplayItem: Identifiable {
    case single(WorkstreamTimelineEvent)
    case cluster(
        id: String,
        events: [WorkstreamTimelineEvent],
        representativeTimestamp: Date,
        dominantSeverity: WorkstreamEventSeverity
    )

    var id: String {
        switch self {
        case .single(let event):
            return event.id
        case .cluster(let id, _, _, _):
            return id
        }
    }

    var timestamp: Date {
        switch self {
        case .single(let event):
            return event.timestamp
        case .cluster(_, _, let ts, _):
            return ts
        }
    }

    var severity: WorkstreamEventSeverity {
        switch self {
        case .single(let event):
            return event.severity
        case .cluster(_, _, _, let sev):
            return sev
        }
    }
}

// MARK: - TimelineClusterEngine

/// Groups consecutive timeline events that fall within a configurable
/// time window into collapsed clusters. Coach findings sharing the
/// same `coachFindingId` always cluster together regardless of timing.
struct TimelineClusterEngine {

    let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = 3.0) {
        self.windowSeconds = windowSeconds
    }

    // MARK: - Public

    func cluster(events: [WorkstreamTimelineEvent]) -> [TimelineDisplayItem] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        var groups: [[WorkstreamTimelineEvent]] = []
        var current: [WorkstreamTimelineEvent] = [sorted[0]]

        for i in 1..<sorted.count {
            let event = sorted[i]
            let previous = current.last!
            if shouldMerge(previous: previous, next: event) {
                current.append(event)
            } else {
                groups.append(current)
                current = [event]
            }
        }
        groups.append(current)

        return groups.map(displayItem)
    }

    // MARK: - Private

    private func shouldMerge(
        previous: WorkstreamTimelineEvent,
        next: WorkstreamTimelineEvent
    ) -> Bool {
        if let prevId = previous.coachFindingId,
           let nextId = next.coachFindingId,
           prevId == nextId {
            return true
        }
        return next.timestamp.timeIntervalSince(previous.timestamp) <= windowSeconds
    }

    private func displayItem(from group: [WorkstreamTimelineEvent]) -> TimelineDisplayItem {
        if group.count == 1 {
            return .single(group[0])
        }
        let representative = group[group.count / 2].timestamp
        let dominant = dominantSeverity(in: group)
        let combinedId = "cluster_" + group.map(\.id).joined(separator: "_")
        return .cluster(
            id: combinedId,
            events: group,
            representativeTimestamp: representative,
            dominantSeverity: dominant
        )
    }

    private func dominantSeverity(
        in events: [WorkstreamTimelineEvent]
    ) -> WorkstreamEventSeverity {
        if events.contains(where: { $0.severity == .critical }) { return .critical }
        if events.contains(where: { $0.severity == .warning }) { return .warning }
        return .info
    }
}
