import AppKit

extension HotkeyRegistry {
    static let overlayKeyboardEntries: [HotkeyRegistryEntry] = [
        .init(
            id: "overlayNextFocus",
            title: "Next Focus Target",
            shortcut: "Tab",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayNextFocus
        ),
        .init(
            id: "overlayPreviousFocus",
            title: "Previous Focus Target",
            shortcut: "Shift+Tab",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayPreviousFocus
        ),
        .init(
            id: "overlayMoveSelection",
            title: "Move Selection",
            shortcut: "Arrow Keys",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .disabledOutsideTarget,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: nil
        ),
        .init(
            id: "overlayActivate",
            title: "Activate Selection",
            shortcut: "Return",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayActivate
        ),
        .init(
            id: "overlayToggle",
            title: "Toggle / Space",
            shortcut: "Space",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlaySpace
        ),
        .init(
            id: "overlayBackspace",
            title: "Delete Backward",
            shortcut: "Delete",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayDeleteBackward
        ),
        .init(
            id: "overlayDeleteSelection",
            title: "Delete Selected Thread",
            shortcut: "Cmd+Delete",
            scope: .overlayLocal,
            owner: .history,
            conflictPolicy: .disabledOutsideTarget,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayDeleteSelection
        ),
        .init(
            id: "overlayDismiss",
            title: "Dismiss / Cancel",
            shortcut: "Escape",
            scope: .overlayLocal,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlayKeyboard,
            persistedBindingKey: nil,
            binding: .overlayDismiss
        )
    ]
}
