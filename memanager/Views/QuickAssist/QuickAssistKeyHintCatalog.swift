import Foundation

/// The shortcuts the keyboard row prints, all resolved through the catalog
/// so a rebinding in Settings updates the copy.
enum QuickAssistKeyHintCatalog {
    typealias Hint = (label: String, shortcut: String)

    static var hints: [Hint] {
        [
            ("Generate", ShortcutCatalog.quickAssist),
            ("Deep", ShortcutCatalog.quickAssistDeep),
            ("Follow up", ShortcutCatalog.quickAssistFollowUp),
            ("Side question", ShortcutCatalog.quickAssistAutoSideQuestion),
            ("Focus question", ShortcutCatalog.quickAssistFocusQuestion),
            ("Cycle mode", ShortcutCatalog.quickAssistCycleMode),
            ("Previous turn", ShortcutCatalog.quickAssistPreviousTurn),
            ("Next turn", ShortcutCatalog.quickAssistNextTurn),
            ("Search threads", ShortcutCatalog.quickAssistFocusHistorySearch)
        ]
    }
}
