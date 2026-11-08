import Foundation

/// Pairs two directional shortcuts into one key cap string. "Cmd+Option+Left"
/// and "Cmd+Option+Right" become "Cmd+Option+Left/Right", which `KeyCap`
/// renders as a single chip. Shortcuts that share no modifiers are listed
/// side by side instead.
enum DesignShortcutHints {
    static func pair(_ first: String, _ second: String) -> String {
        let firstTokens = first.split(separator: "+").map(String.init)
        let secondTokens = second.split(separator: "+").map(String.init)
        guard firstTokens.count == secondTokens.count,
              firstTokens.count > 1,
              Array(firstTokens.dropLast()) == Array(secondTokens.dropLast()),
              let firstKey = firstTokens.last,
              let secondKey = secondTokens.last else {
            return "\(first) \(second)"
        }
        return (firstTokens.dropLast() + ["\(firstKey)/\(secondKey)"]).joined(separator: "+")
    }

    /// Previous and next progressive step, Cmd+Option+Left/Right by default.
    static var step: String {
        pair(ShortcutCatalog.quickAssistPreviousTurn, ShortcutCatalog.quickAssistNextTurn)
    }

    /// Previous and next section, or teleprompter chunk, Cmd+Up/Down by default.
    static var section: String {
        pair(ShortcutCatalog.previousChunk, ShortcutCatalog.nextChunk)
    }

    static var teleprompter: String {
        ShortcutCatalog.toggleTeleprompter
    }
}
