import CoreGraphics

/// Panes of the History screen. Sessions is a column of its own above the
/// compact breakpoint and one more pane below it.
enum HistoryPane: String, CaseIterable, Identifiable, Hashable {
    case sessions
    case overview
    case timeline
    case replay
    case debrief

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .overview: return "Summary"
        case .timeline: return "Timeline"
        case .replay: return "Evidence"
        case .debrief: return "Debrief"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .overview: return "list.bullet.clipboard"
        case .timeline: return "timeline.selection"
        case .replay: return "doc.text.viewfinder"
        case .debrief: return "doc.text.magnifyingglass"
        }
    }
}

/// How the History screen arranges its panes at a given width.
enum HistoryLayoutMode: Equatable {
    /// One pane at a time behind a segment strip that includes Sessions.
    case stacked
    /// The session list beside the detail panes.
    case twoColumn
}

/// Pure width rules for the History screen so layout decisions are testable.
struct SessionHistoryLayoutResolver: Equatable {
    let width: CGFloat

    var mode: HistoryLayoutMode {
        MasterDetailLayoutResolver.isSplit(width: width) ? .twoColumn : .stacked
    }

    /// Panes offered in the segment strip for this width.
    var panes: [HistoryPane] {
        switch mode {
        case .stacked: return HistoryPane.allCases
        case .twoColumn: return HistoryPane.allCases.filter { $0 != .sessions }
        }
    }

    /// The pane that can be shown: the session list is its own column in
    /// the two column layout, so a request for it falls back to Overview.
    func resolvedPane(_ requested: HistoryPane) -> HistoryPane {
        if mode == .twoColumn, requested == .sessions { return .overview }
        return requested
    }

    var listWidth: CGFloat {
        OverlayColumnWidth.list(for: width)
    }
}
