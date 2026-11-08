import AppKit
import Carbon
import ApplicationServices

extension HotkeyManager {
    // Default hotkey bindings
    struct Hotkey: Codable, Equatable, Hashable {
        var keyCode: UInt16
        var modifiers: CGEventFlags

        init(keyCode: UInt16, modifiers: CGEventFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            keyCode = try values.decode(UInt16.self, forKey: .keyCode)
            modifiers = CGEventFlags(rawValue: try values.decode(UInt64.self, forKey: .modifiers))
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(keyCode, forKey: .keyCode)
            try values.encode(modifiers.rawValue, forKey: .modifiers)
        }

        static let toggleVisibility = Hotkey(keyCode: 2, modifiers: .maskCommand) // Cmd+D
        static let startSession = Hotkey(keyCode: 1, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+S
        static let screenshot = Hotkey(keyCode: 7, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+X
        static let solve = Hotkey(keyCode: 36, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+Return
        static let resetSession = Hotkey(keyCode: 15, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+R
        static let togglePause = Hotkey(keyCode: 35, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+P
        static let endSession = Hotkey(keyCode: 14, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+E
        static let openTranscriptLog = Hotkey(keyCode: 17, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+T
        static let nextSection = Hotkey(keyCode: 30, modifiers: .maskCommand) // Cmd+]
        static let prevSection = Hotkey(keyCode: 33, modifiers: .maskCommand) // Cmd+[
        static let openSettings = Hotkey(keyCode: 32, modifiers: .maskCommand) // Cmd+U
        static let quit = Hotkey(keyCode: 14, modifiers: .maskCommand) // Cmd+E
        static let scrollDown = Hotkey(keyCode: 124, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+Right
        static let scrollUp = Hotkey(keyCode: 123, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+Left
        static let legacyScrollDown = Hotkey(keyCode: 124, modifiers: .maskCommand) // Cmd+Right (pre-v19 default)
        static let legacyScrollUp = Hotkey(keyCode: 123, modifiers: .maskCommand) // Cmd+Left (pre-v19 default)
        static let increaseWidth = Hotkey(keyCode: 24, modifiers: .maskCommand) // Cmd+= (plus key)
        static let decreaseWidth = Hotkey(keyCode: 27, modifiers: .maskCommand) // Cmd+- (hyphen key)
        static let anchorLeft = Hotkey(keyCode: UInt16(kVK_ANSI_J), modifiers: .maskCommand) // Cmd+J
        static let anchorRight = Hotkey(keyCode: UInt16(kVK_ANSI_K), modifiers: .maskCommand) // Cmd+K
        static let nextStep = Hotkey(keyCode: 47, modifiers: .maskCommand) // Cmd+. (period)
        static let prevStep = Hotkey(keyCode: 43, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+, (comma)
        static let nextDesignStep = Hotkey(keyCode: 124, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+Right
        static let prevDesignStep = Hotkey(keyCode: 123, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+Left
        static let quickAssist = Hotkey(keyCode: 44, modifiers: .maskCommand) // Cmd+/
        static let markCurrentSpeaker = Hotkey(keyCode: UInt16(kVK_ANSI_M), modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+M
        static let toggleSpeakerIdMode = Hotkey(keyCode: UInt16(kVK_ANSI_I), modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+I
        static let toggleDiagnostics = Hotkey(keyCode: 2, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+D
        static let toggleTeleprompter = Hotkey(keyCode: UInt16(kVK_ANSI_T), modifiers: .maskCommand) // Cmd+T
        static let nextChunk = Hotkey(keyCode: 125, modifiers: .maskCommand) // Cmd+Down
        static let prevChunk = Hotkey(keyCode: 126, modifiers: .maskCommand) // Cmd+Up
        static let solveSystemDesign = Hotkey(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+Y
        static let cancelRequest = Hotkey(keyCode: 47, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+. (period)
        static let cycleProvider = Hotkey(keyCode: 44, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+/
        static let quickAssistFollowUp = Hotkey(keyCode: 39, modifiers: .maskCommand) // Cmd+' (quote key)
        static let quickAssistImplementationContext = Hotkey(keyCode: UInt16(kVK_ANSI_1), modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+1 (all sections context)
        static let quickAssistSystemDesignContext = Hotkey(keyCode: UInt16(kVK_ANSI_2), modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+2
        static let quickAssistDeep = Hotkey(keyCode: 44, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+/
        static let quickAssistAutoSideQuestion = Hotkey(keyCode: 41, modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+; (semicolon key)
        static let quickAssistFocusQuestion = Hotkey(keyCode: UInt16(kVK_ANSI_L), modifiers: .maskCommand) // Cmd+L
        static let quickAssistCycleMode = Hotkey(keyCode: UInt16(kVK_ANSI_0), modifiers: .maskCommand) // Cmd+0
        static let quickAssistFocusHistorySearch = Hotkey(keyCode: UInt16(kVK_ANSI_L), modifiers: [.maskCommand, .maskShift]) // Cmd+Shift+L
        static let quickAssistHistoryNextThread = Hotkey(keyCode: 125, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+Down
        static let quickAssistHistoryPrevThread = Hotkey(keyCode: 126, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+Up
        static let quickAssistHistoryOpenThread = Hotkey(keyCode: 36, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+Return
        static let cycleLiveResponseCard = Hotkey(keyCode: 41, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+;
        static let pinLiveResponseCard = Hotkey(keyCode: 39, modifiers: [.maskCommand, .maskAlternate]) // Cmd+Option+'
        static let overlayNextFocus = Hotkey(keyCode: 48, modifiers: []) // Tab
        static let overlayPreviousFocus = Hotkey(keyCode: 48, modifiers: [.maskShift]) // Shift+Tab
        static let overlayActivate = Hotkey(keyCode: 36, modifiers: []) // Return
        static let overlaySpace = Hotkey(keyCode: 49, modifiers: []) // Space
        static let overlayDeleteBackward = Hotkey(keyCode: 51, modifiers: []) // Delete
        static let overlayDeleteSelection = Hotkey(keyCode: 51, modifiers: [.maskCommand]) // Cmd+Delete
        static let overlayDismiss = Hotkey(keyCode: 53, modifiers: []) // Escape

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifiers.rawValue)
        }
    }

}
