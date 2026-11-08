import AppKit

extension HotkeyRegistry {
    static let overlayEntries: [HotkeyRegistryEntry] = [
        .init(
            id: "increaseWidth",
            title: "Increase Width",
            shortcut: "Cmd+=",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlay,
            persistedBindingKey: "increaseWidth",
            binding: .increaseWidth
        ),
        .init(
            id: "decreaseWidth",
            title: "Decrease Width",
            shortcut: "Cmd+-",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlay,
            persistedBindingKey: "decreaseWidth",
            binding: .decreaseWidth
        ),
        .init(
            id: "anchorLeft",
            title: "Anchor Left",
            shortcut: "Cmd+J",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlay,
            persistedBindingKey: "anchorLeft",
            binding: .anchorLeft
        ),
        .init(
            id: "anchorRight",
            title: "Anchor Right",
            shortcut: "Cmd+K",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .overlay,
            persistedBindingKey: "anchorRight",
            binding: .anchorRight
        )
    ]
}
