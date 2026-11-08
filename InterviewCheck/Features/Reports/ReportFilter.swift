import Foundation

enum ReportSort: String, CaseIterable, Identifiable {
    case newest, oldest, highestScore, candidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .highestScore: return "Highest score"
        case .candidate: return "Candidate A–Z"
        }
    }
}

/// Search, filters and order for the Reports list.
struct ReportFilter {
    var search = ""
    var flaggedOnly = false
    var roleTitle: String?
    var sort = ReportSort.newest

    func apply(_ interviews: [InterviewRecord]) -> [InterviewRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = interviews.filter { interview in
            if !query.isEmpty, !"\(interview.candidateName) \(interview.roleTitle)".lowercased().contains(query) {
                return false
            }
            if flaggedOnly, interview.flaggedCount == 0 { return false }
            if let roleTitle, interview.roleTitle != roleTitle { return false }
            return true
        }
        switch sort {
        case .newest:
            return kept.sorted { $0.startedAt > $1.startedAt }
        case .oldest:
            return kept.sorted { $0.startedAt < $1.startedAt }
        case .highestScore:
            // Unscored interviews last; ties newest first.
            return kept.sorted {
                let left = $0.overallPercent ?? -1, right = $1.overallPercent ?? -1
                return left != right ? left > right : $0.startedAt > $1.startedAt
            }
        case .candidate:
            return kept.sorted {
                $0.candidateName.localizedStandardCompare($1.candidateName) == .orderedAscending
            }
        }
    }
}
