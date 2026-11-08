import AppKit
import Carbon
import ApplicationServices

extension HotkeyManager {
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    static func isCommandOnlyShortcut(_ flags: CGEventFlags) -> Bool {
        normalizedModifierFlags(flags) == .maskCommand
    }

    static func sectionIndexForCommandOnlyKey(keyCode: UInt16, flags: CGEventFlags) -> Int? {
        guard isCommandOnlyShortcut(flags) else { return nil }
        let sectionKeys: [UInt16: Int] = [
            18: 0, // 1
            19: 1, // 2
            20: 2, // 3
            21: 3, // 4
            23: 4, // 5
            22: 5  // 6
        ]
        return sectionKeys[keyCode]
    }

    static func quickAssistContextMode(
        keyCode: UInt16,
        flags: CGEventFlags,
        allSectionsHotkey: Hotkey?,
        systemDesignHotkey: Hotkey?
    ) -> QuickAssistContextMode? {
        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: allSectionsHotkey) {
            return .allSectionsContext
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: systemDesignHotkey) {
            return .systemDesignContext
        }

        return nil
    }

    enum CommandOptionArrowAction {
        case nextDesignStep
        case prevDesignStep
        case nextQuickAssistResponse
        case prevQuickAssistResponse
    }

    static func commandOptionArrowAction(
        keyCode: UInt16,
        flags: CGEventFlags,
        nextDesignHotkey: Hotkey?,
        prevDesignHotkey: Hotkey?,
        quickAssistHistoryEnabled: Bool,
        systemDesignActive: Bool = false
    ) -> CommandOptionArrowAction? {
        // Context aware routing: while the system design surface is
        // frontmost, the shared Cmd+Option arrow chords navigate design
        // steps even when Quick Assist history is enabled (previously
        // history unconditionally won, silently disabling step navigation).
        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: nextDesignHotkey) {
            if systemDesignActive { return .nextDesignStep }
            return quickAssistHistoryEnabled ? .nextQuickAssistResponse : .nextDesignStep
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: prevDesignHotkey) {
            if systemDesignActive { return .prevDesignStep }
            return quickAssistHistoryEnabled ? .prevQuickAssistResponse : .prevDesignStep
        }

        return nil
    }

    static func teleprompterHotkeysEnabled(gate: (() -> Bool)?) -> Bool {
        gate?() ?? true
    }

    static func quickAssistHistoryHotkeysEnabled(gate: (() -> Bool)?) -> Bool {
        gate?() ?? false
    }

    static func quickAssistModeHotkeysEnabled(gate: (() -> Bool)?) -> Bool {
        gate?() ?? false
    }

    static func overlayCommand(keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> OverlayCommand? {
        let normalizedFlags = normalizedModifierFlags(flags)

        if normalizedFlags.contains(.maskCommand) || normalizedFlags.contains(.maskAlternate) || normalizedFlags.contains(.maskControl) {
            if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayDeleteSelection) {
                return .deleteSelection
            }
            return nil
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayNextFocus) {
            return .nextFocus
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayPreviousFocus) {
            return .previousFocus
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayActivate) {
            return .activate
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayDismiss) {
            return .dismiss
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlayDeleteBackward) {
            return .deleteBackward
        }

        if matchesHotkey(keyCode: keyCode, flags: flags, hotkey: .overlaySpace) {
            return .space
        }

        switch keyCode {
        case 123:
            return .moveLeft
        case 124:
            return .moveRight
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        default:
            break
        }

        let text = unicodeText(from: event)
        guard !text.isEmpty else { return nil }
        return .insertText(text)
    }

    static func matchesHotkey(keyCode: UInt16, flags: CGEventFlags, hotkey: Hotkey?) -> Bool {
        guard let hotkey = hotkey else { return false }

        let maskedEventFlags = normalizedModifierFlags(flags)
        let maskedHotkeyFlags = normalizedModifierFlags(hotkey.modifiers)

        return keyCode == hotkey.keyCode && maskedEventFlags == maskedHotkeyFlags
    }

    private static func normalizedModifierFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(relevantModifierFlags)
    }

    private static func unicodeText(from event: CGEvent) -> String {
        let maxLength = 8
        let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: maxLength)
        defer { buffer.deallocate() }

        var actualLength = 0
        event.keyboardGetUnicodeString(
            maxStringLength: maxLength,
            actualStringLength: &actualLength,
            unicodeString: buffer
        )

        guard actualLength > 0 else { return "" }
        let text = String(utf16CodeUnits: buffer, count: actualLength)
        return text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
    }

}
