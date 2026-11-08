import Foundation

/// Pure rules behind the turn navigator: which turn is current, what the
/// counter says, and when the chevrons are disabled.
struct QuickAssistTurnNavigatorModel: Equatable {
    let turnSummaries: [QuickAssistTurnSummary]
    let selectedIndex: Int?
    let isLoading: Bool

    var count: Int { turnSummaries.count }

    var isEmpty: Bool { turnSummaries.isEmpty }

    var effectiveSelected: Int {
        selectedIndex ?? max(count - 1, 0)
    }

    var label: String {
        guard count > 0 else { return "0 of 0" }
        return "\(effectiveSelected + 1) of \(count)"
    }

    var isPreviousDisabled: Bool {
        isLoading || effectiveSelected <= 0
    }

    var isNextDisabled: Bool {
        isLoading || effectiveSelected >= count - 1
    }

    func isSelected(_ summary: QuickAssistTurnSummary) -> Bool {
        summary.index == effectiveSelected
    }

    func tone(for summary: QuickAssistTurnSummary) -> OverlayTone {
        summary.verificationStatus?.tone ?? .neutral
    }
}
