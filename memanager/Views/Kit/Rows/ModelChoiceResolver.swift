import Foundation

/// Where a model identifier came from: the curated menu or typed by hand.
enum ModelChoice: Equatable {
    case curated(String)
    case custom(String)

    var model: String {
        switch self {
        case .curated(let model), .custom(let model): return model
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// Pure rules for the model menu: which entry is selected for a stored
/// identifier, and what the menu button should say.
enum ModelChoiceResolver {
    static let customTitle = "Custom"

    static func choice(for model: String, curated: [String]) -> ModelChoice {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if curated.contains(trimmed) { return .curated(trimmed) }
        return .custom(trimmed)
    }

    static func menuTitle(for choice: ModelChoice) -> String {
        switch choice {
        case .curated(let model): return model
        case .custom: return customTitle
        }
    }

    /// The identifier to store when the user picks a menu entry. Choosing
    /// Custom keeps whatever was typed unless it was a curated name, so the
    /// field starts empty and invites a new value.
    static func model(afterSelecting selection: String?, current: String, curated: [String]) -> String {
        guard let selection else {
            return curated.contains(current) ? "" : current
        }
        return selection
    }
}
