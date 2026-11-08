import Foundation

/// Where the review session stands: cards graded so far against the cards
/// still due, as a fraction for the track and a short label.
struct PracticeSessionProgress: Equatable {
    let graded: Int
    let due: Int

    var total: Int { graded + due }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(graded) / Double(total)
    }

    var label: String {
        guard total > 0 else { return "Deck clear" }
        return "\(graded) of \(total) graded"
    }
}
