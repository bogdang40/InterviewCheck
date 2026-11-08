import Foundation

/// Single place views ask for the key that triggers an action, so copy
/// never hard codes a shortcut. Resolution goes through the hotkey registry
/// by id; callers pass a fallback for actions the registry groups (such as
/// the numbered section jumps).
enum ShortcutCatalog {
    static func shortcut(for hotkeyID: String, fallback: String = "") -> String {
        HotkeyRegistry.entries.first(where: { $0.id == hotkeyID })?.shortcut ?? fallback
    }

    // MARK: Session

    static var toggleOverlay: String { shortcut(for: "toggleVisibility", fallback: "Cmd+D") }
    static var startSession: String { shortcut(for: "startSession", fallback: "Cmd+Shift+S") }
    static var togglePause: String { shortcut(for: "togglePause", fallback: "Cmd+Shift+P") }
    static var endSession: String { shortcut(for: "endSession", fallback: "Cmd+Shift+E") }
    static var resetSession: String { shortcut(for: "resetSession", fallback: "Cmd+Shift+R") }
    static var screenshot: String { shortcut(for: "screenshot", fallback: "Cmd+Shift+X") }
    static var cancelRequest: String { shortcut(for: "cancelRequest", fallback: "Cmd+Shift+.") }
    static var cycleProvider: String { shortcut(for: "cycleProvider", fallback: "Cmd+Shift+/") }
    static var openSettings: String { shortcut(for: "openSettings", fallback: "Cmd+U") }
    static var quit: String { shortcut(for: "quit", fallback: "Cmd+E") }

    // MARK: Surfaces

    static var solve: String { shortcut(for: "solve", fallback: "Cmd+Shift+Return") }
    static var solveSystemDesign: String { shortcut(for: "solveSystemDesign", fallback: "Cmd+Shift+Y") }
    static var showQuickAssist: String { shortcut(for: "showQuickAssistView", fallback: "Cmd+7") }
    static var openTranscript: String { shortcut(for: "openTranscriptLog", fallback: "Cmd+Shift+T") }
    static var nextSection: String { shortcut(for: "nextSection", fallback: "Cmd+]") }
    static var previousSection: String { shortcut(for: "prevSection", fallback: "Cmd+[") }

    static func jumpToSection(_ section: MentorResponse.Section) -> String {
        "Cmd+\(section.rawValue + 1)"
    }

    // MARK: Quick Assist

    static var quickAssist: String { shortcut(for: "quickAssist", fallback: "Cmd+/") }
    static var quickAssistDeep: String { shortcut(for: "quickAssistDeep", fallback: "Cmd+Option+/") }
    static var quickAssistFollowUp: String { shortcut(for: "quickAssistFollowUp", fallback: "Cmd+'") }
    static var quickAssistAutoSideQuestion: String { shortcut(for: "quickAssistAutoSideQuestion", fallback: "Cmd+Shift+;") }
    static var quickAssistFocusQuestion: String { shortcut(for: "quickAssistFocusQuestion", fallback: "Cmd+L") }
    static var quickAssistCycleMode: String { shortcut(for: "quickAssistCycleMode", fallback: "Cmd+0") }
    static var quickAssistPreviousTurn: String { shortcut(for: "prevContextualStep", fallback: "Cmd+Option+Left") }
    static var quickAssistNextTurn: String { shortcut(for: "nextContextualStep", fallback: "Cmd+Option+Right") }
    static var quickAssistFocusHistorySearch: String { shortcut(for: "quickAssistFocusHistorySearch", fallback: "Cmd+Shift+L") }

    // MARK: Reading

    static var nextStep: String { shortcut(for: "nextStep", fallback: "Cmd+.") }
    static var previousStep: String { shortcut(for: "prevStep", fallback: "Cmd+Shift+,") }
    static var toggleTeleprompter: String { shortcut(for: "toggleTeleprompter", fallback: "Cmd+T") }
    static var nextChunk: String { shortcut(for: "nextChunk", fallback: "Cmd+Down") }
    static var previousChunk: String { shortcut(for: "prevChunk", fallback: "Cmd+Up") }
    static var scrollDown: String { shortcut(for: "scrollDown", fallback: "Cmd+Shift+Right") }
    static var scrollUp: String { shortcut(for: "scrollUp", fallback: "Cmd+Shift+Left") }
    static var toggleDiagnostics: String { shortcut(for: "toggleDiagnostics", fallback: "Cmd+Shift+D") }
}
