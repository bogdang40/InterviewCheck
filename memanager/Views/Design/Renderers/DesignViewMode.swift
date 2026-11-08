import Foundation

/// The three ways to read a settled design answer: one card per section,
/// a compact overview, or the talk through script.
enum DesignViewMode: String, CaseIterable, Identifiable {
    case sections
    case overview
    case script

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sections: return "Sections"
        case .overview: return "Overview"
        case .script: return "Script"
        }
    }

    var systemImage: String {
        switch self {
        case .sections: return "list.number"
        case .overview: return "square.grid.2x2"
        case .script: return "text.alignleft"
        }
    }

    static var segments: [SegmentItem<DesignViewMode>] {
        allCases.map { SegmentItem(id: $0, title: $0.title, systemImage: $0.systemImage) }
    }
}
