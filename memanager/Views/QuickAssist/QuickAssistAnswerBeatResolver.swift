import Foundation

/// How one beat of the answer should be presented.
struct QuickAssistBeatPlan: Equatable {
    let number: Int
    let title: String?
    let isEmphasized: Bool
    let caption: String?
}

/// Numbers the beats and decides which one carries the accent. Behavioural
/// answers are graded on the Action beat, so STAR style frameworks emphasise
/// it and tell the candidate to spend the most words there.
enum QuickAssistAnswerBeatResolver {
    static let emphasisCaption = "Say the most about this"

    static func plans(titles: [String?], frameworkName: String?) -> [QuickAssistBeatPlan] {
        let emphasiseAction = isStarFramework(frameworkName)
        return titles.enumerated().map { index, title in
            let cleaned = cleanTitle(title)
            let emphasized = emphasiseAction && isActionBeat(cleaned)
            return QuickAssistBeatPlan(
                number: index + 1,
                title: cleaned,
                isEmphasized: emphasized,
                caption: emphasized ? emphasisCaption : nil
            )
        }
    }

    static func isStarFramework(_ frameworkName: String?) -> Bool {
        guard let frameworkName else { return false }
        return frameworkName.uppercased().contains("STAR")
    }

    static func isActionBeat(_ title: String?) -> Bool {
        guard let title else { return false }
        let first = title.lowercased().split(whereSeparator: { !$0.isLetter }).first
        return first == "action" || first == "actions"
    }

    /// Untitled beats render without a fabricated heading; the numbering
    /// already separates them.
    private static func cleanTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
