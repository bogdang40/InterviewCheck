import AppKit

extension HotkeyRegistry {
    static let navigationEntries: [HotkeyRegistryEntry] = [
        .init(
            id: "nextSection",
            title: "Next Section",
            shortcut: "Cmd+]",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "nextSection",
            binding: .nextSection
        ),
        .init(
            id: "prevSection",
            title: "Previous Section",
            shortcut: "Cmd+[",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "prevSection",
            binding: .prevSection
        ),
        .init(
            id: "scrollDown",
            title: "Scroll Down",
            shortcut: "Cmd+Shift+Right",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "scrollDown",
            binding: .scrollDown
        ),
        .init(
            id: "scrollUp",
            title: "Scroll Up",
            shortcut: "Cmd+Shift+Left",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "scrollUp",
            binding: .scrollUp
        ),
        .init(
            id: "nextStep",
            title: "Next Implementation Step",
            shortcut: "Cmd+.",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "nextStep",
            binding: .nextStep
        ),
        .init(
            id: "prevStep",
            title: "Previous Implementation Step",
            shortcut: "Cmd+Shift+,",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: "prevStep",
            binding: .prevStep
        ),
        .init(
            id: "nextContextualStep",
            title: "Next Design Step / Next QA Response",
            shortcut: "Cmd+Option+Right",
            scope: .contextLocal,
            owner: .quickAssist,
            conflictPolicy: .contextSwitched,
            section: .navigation,
            persistedBindingKey: "nextDesignStep",
            binding: .nextDesignStep
        ),
        .init(
            id: "prevContextualStep",
            title: "Previous Design Step / Prev QA Response",
            shortcut: "Cmd+Option+Left",
            scope: .contextLocal,
            owner: .quickAssist,
            conflictPolicy: .contextSwitched,
            section: .navigation,
            persistedBindingKey: "prevDesignStep",
            binding: .prevDesignStep
        ),
        .init(
            id: "jumpSections",
            title: "Jump to Section",
            shortcut: "Cmd+1-6",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: nil,
            binding: nil
        ),
        .init(
            id: "showQuickAssistView",
            title: "Show Quick Assist",
            shortcut: "Cmd+7",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .navigation,
            persistedBindingKey: nil,
            binding: nil
        ),
        .init(
            id: "toggleTeleprompter",
            title: "Toggle Teleprompter",
            shortcut: "Cmd+T",
            scope: .contextLocal,
            owner: .teleprompter,
            conflictPolicy: .disabledOutsideTarget,
            section: .navigation,
            persistedBindingKey: "toggleTeleprompter",
            binding: .toggleTeleprompter
        ),
        .init(
            id: "nextChunk",
            title: "Next Chunk",
            shortcut: "Cmd+Down",
            scope: .contextLocal,
            owner: .teleprompter,
            conflictPolicy: .disabledOutsideTarget,
            section: .navigation,
            persistedBindingKey: "nextChunk",
            binding: .nextChunk
        ),
        .init(
            id: "prevChunk",
            title: "Previous Chunk",
            shortcut: "Cmd+Up",
            scope: .contextLocal,
            owner: .teleprompter,
            conflictPolicy: .disabledOutsideTarget,
            section: .navigation,
            persistedBindingKey: "prevChunk",
            binding: .prevChunk
        )
    ]
}
