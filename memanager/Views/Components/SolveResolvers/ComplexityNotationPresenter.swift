import Foundation

/// What a complexity tile shows: the notation as the value, the kind as
/// the label, and the breakdown as the caption underneath.
struct ComplexityTilePresentation: Equatable {
    let value: String
    let label: String
    let caption: String?
    let isStated: Bool
}

/// The parser falls back to a literal question mark notation when the
/// model never stated one. The overlay must never print that placeholder,
/// so this presenter swaps it for plain words the user can say.
enum ComplexityNotationPresenter {
    static let unstatedValue = "Unknown"
    static let unstatedCaption = "Not stated"

    static func isStated(_ notation: String) -> Bool {
        let trimmed = notation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains("?")
    }

    static func presentation(for analysis: ComplexityAnalysis) -> ComplexityTilePresentation {
        let stated = isStated(analysis.notation)
        let breakdown = analysis.breakdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption: String?
        if stated {
            caption = breakdown.isEmpty ? nil : breakdown
        } else if breakdown.isEmpty {
            caption = unstatedCaption
        } else {
            caption = "\(unstatedCaption). \(breakdown)"
        }
        return ComplexityTilePresentation(
            value: stated ? analysis.notation.trimmingCharacters(in: .whitespacesAndNewlines) : unstatedValue,
            label: analysis.type.rawValue,
            caption: caption,
            isStated: stated
        )
    }
}
