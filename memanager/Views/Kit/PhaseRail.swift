import SwiftUI

/// One phase on a `PhaseRail`.
struct PhaseRailItem: Identifiable, Equatable {
    let id: Int
    let title: String
    var minutes: Int? = nil
    var isComplete: Bool = false
}

/// Progress rail with a time budget per phase. Built for the system design
/// surface, where interviewers expect a five phase shape with a known
/// budget, but generic enough for any staged flow.
struct PhaseRail: View {
    let items: [PhaseRailItem]
    let currentIndex: Int
    var compact: Bool = false
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(items) { item in
                PhaseRailSegment(
                    item: item,
                    state: state(for: item),
                    compact: compact
                ) {
                    onSelect?(item.id)
                }
            }
        }
    }

    private func state(for item: PhaseRailItem) -> PhaseRailSegment.State {
        if item.id == currentIndex { return .current }
        if item.isComplete || item.id < currentIndex { return .complete }
        return .upcoming
    }
}

struct PhaseRailSegment: View {
    enum State {
        case complete
        case current
        case upcoming
    }

    let item: PhaseRailItem
    let state: State
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(barColor)
                    .frame(height: 3)
                if !compact {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(state == .current ? OverlayType.captionStrong : OverlayType.caption)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        if let minutes = item.minutes {
                            Text("\(minutes)m")
                                .font(OverlayType.monoMicro)
                                .foregroundStyle(OverlayPalette.textTertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var barColor: Color {
        switch state {
        case .complete: return OverlayTone.success.color.opacity(0.7)
        case .current: return OverlayPalette.accent
        case .upcoming: return OverlayPalette.hairlineStrong
        }
    }

    private var titleColor: Color {
        switch state {
        case .complete: return OverlayPalette.textSecondary
        case .current: return OverlayPalette.textPrimary
        case .upcoming: return OverlayPalette.textTertiary
        }
    }

    private var helpText: String {
        if let minutes = item.minutes {
            return "\(item.title), about \(minutes) minutes"
        }
        return item.title
    }
}
