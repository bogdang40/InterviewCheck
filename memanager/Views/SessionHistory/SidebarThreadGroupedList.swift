import SwiftUI

/// Buckets for the thread list, newest first.
enum SidebarDateBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"
}

struct ThreadDateGroup: Identifiable {
    let bucket: SidebarDateBucket
    let threads: [QuickAssistThreadSummary]
    var id: String { bucket.rawValue }

    static func group(_ threads: [QuickAssistThreadSummary], calendar: Calendar = .current, now: Date = Date()) -> [ThreadDateGroup] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        var buckets: [SidebarDateBucket: [QuickAssistThreadSummary]] = [:]
        for thread in threads {
            let date = thread.lastTurnAt ?? thread.updatedAt
            let bucket: SidebarDateBucket
            if date >= startOfToday {
                bucket = .today
            } else if date >= startOfYesterday {
                bucket = .yesterday
            } else {
                bucket = .earlier
            }
            buckets[bucket, default: []].append(thread)
        }
        return SidebarDateBucket.allCases.compactMap { bucket in
            guard let threads = buckets[bucket], !threads.isEmpty else { return nil }
            return ThreadDateGroup(bucket: bucket, threads: threads)
        }
    }
}

/// The grouped thread list with a small header per date bucket.
struct SidebarThreadGroupedList: View {
    let groups: [ThreadDateGroup]
    let rowModel: (QuickAssistThreadSummary) -> QuickAssistThreadRowModel
    let onSelect: (QuickAssistThreadSummary) -> Void
    let onDelete: (QuickAssistThreadSummary) -> Void
    let onInspect: (QuickAssistThreadSummary) -> Void

    @Binding var batchSelection: HistoryBatchSelection
    let eligibleIDs: Set<String>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(groups) { group in
                header(for: group)
                ForEach(group.threads) { thread in
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if batchSelection.isSelecting {
                            HistorySelectionCheckbox(id: thread.id, title: thread.title, selection: $batchSelection, isEnabled: eligibleIDs.contains(thread.id))
                        }
                        SidebarThreadCard(
                            model: rowModel(thread),
                            onSelect: {
                                if batchSelection.isSelecting {
                                    if eligibleIDs.contains(thread.id) { batchSelection.toggle(thread.id) }
                                } else { onSelect(thread) }
                            },
                            onDelete: { onDelete(thread) },
                            onInspect: { onInspect(thread) },
                            selectionOverride: batchSelection.isSelecting ? batchSelection.ids.contains(thread.id) : nil
                        )
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }

    private func header(for group: ThreadDateGroup) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: group.bucket.rawValue)
            CountBadge(count: group.threads.count)
            Spacer(minLength: 0)
            if let verified = verifiedShare(for: group) {
                Text(verified)
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.top, DesignTokens.Spacing.sm)
    }

    private func verifiedShare(for group: ThreadDateGroup) -> String? {
        let fractions = group.threads.compactMap { rowModel($0).metadata?.verifiedFraction }
        guard !fractions.isEmpty else { return nil }
        let average = fractions.reduce(0, +) / Double(fractions.count)
        return "\(Int((average * 100).rounded()))% verified"
    }
}
