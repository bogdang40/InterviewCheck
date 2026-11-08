import Foundation

/// The answer clock starts when the selected turn settles and resets when
/// the user navigates to another turn. The seed remembers which turn the
/// clock belongs to, so the settle and turn change notifications can arrive
/// in either order without losing the start.
struct QuickAssistAnswerClockState: Equatable {
    var startedAt: Date?
    var seed: String?

    static let idle = QuickAssistAnswerClockState(startedAt: nil, seed: nil)

    /// Loading flipped. Starts the clock when a turn just finished and there
    /// is something to read.
    func loadingChanged(wasLoading: Bool, isLoading: Bool, hasResponse: Bool, seed: String?, now: Date) -> QuickAssistAnswerClockState {
        guard wasLoading, !isLoading, hasResponse else { return self }
        return QuickAssistAnswerClockState(startedAt: now, seed: seed)
    }

    /// The displayed turn changed. Keeps the clock only for the turn it was
    /// started for.
    func turnChanged(to seed: String?) -> QuickAssistAnswerClockState {
        guard seed == self.seed else { return .idle }
        return self
    }
}
