import Foundation

/// How a % reads at a glance. The words stay careful: a score is a signal
/// to follow up on, never a verdict.
enum ScoreBand: Equatable {
    case genuine, mixed, flagged

    init(percent: Int) {
        switch percent {
        case ..<40: self = .genuine
        case ..<70: self = .mixed
        default: self = .flagged
        }
    }

    var title: String {
        switch self {
        case .genuine: return "Looks like their own answer"
        case .mixed: return "Some signs of AI help"
        case .flagged: return "Strong signs of AI help"
        }
    }
}
