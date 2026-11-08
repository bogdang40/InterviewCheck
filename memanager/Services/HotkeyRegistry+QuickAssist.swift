import AppKit

extension HotkeyRegistry {
    static let quickAssistEntries: [HotkeyRegistryEntry] = [
        .init(
            id: "quickAssist",
            title: "Quick Assist (Conversation)",
            shortcut: "Cmd+/",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssist",
            binding: .quickAssist
        ),
        .init(
            id: "quickAssistDeep",
            title: "Quick Assist (Deep)",
            shortcut: "Cmd+Option+/",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistDeep",
            binding: .quickAssistDeep
        ),
        .init(
            id: "quickAssistFollowUp",
            title: "Quick Assist (Follow up)",
            shortcut: "Cmd+'",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistFollowUp",
            binding: .quickAssistFollowUp
        ),
        .init(
            id: "quickAssistAutoSideQuestion",
            title: "Quick Assist (Auto Side Question)",
            shortcut: "Cmd+Shift+;",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistAutoSideQuestion",
            binding: .quickAssistAutoSideQuestion
        ),
        .init(
            id: "quickAssistFocusQuestion",
            title: "Quick Assist (Focus Question)",
            shortcut: "Cmd+L",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistFocusQuestion",
            binding: .quickAssistFocusQuestion
        ),
        .init(
            id: "quickAssistCycleMode",
            title: "Quick Assist (Cycle Mode)",
            shortcut: "Cmd+0",
            scope: .contextLocal,
            owner: .quickAssist,
            conflictPolicy: .disabledOutsideTarget,
            section: .quickAssist,
            persistedBindingKey: "quickAssistCycleMode",
            binding: .quickAssistCycleMode
        ),
        .init(
            id: "quickAssistFocusHistorySearch",
            title: "Quick Assist (Focus History Search)",
            shortcut: "Cmd+Shift+L",
            scope: .global,
            owner: .history,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistFocusHistorySearch",
            binding: .quickAssistFocusHistorySearch
        ),
        .init(
            id: "cycleLiveResponseCard",
            title: "Live Response Card Cycle",
            shortcut: "Cmd+Option+;",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "cycleLiveResponseCard",
            binding: .cycleLiveResponseCard
        ),
        .init(
            id: "pinLiveResponseCard",
            title: "Live Response Card Pin",
            shortcut: "Cmd+Option+'",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "pinLiveResponseCard",
            binding: .pinLiveResponseCard
        ),
        .init(
            id: "quickAssistImplementationContext",
            title: "Quick Assist (All Sections Context)",
            shortcut: "Cmd+Option+1",
            scope: .contextLocal,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistImplementationContext",
            binding: .quickAssistImplementationContext
        ),
        .init(
            id: "quickAssistSystemDesignContext",
            title: "Quick Assist (System Design Context)",
            shortcut: "Cmd+Option+2",
            scope: .contextLocal,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quickAssistSystemDesignContext",
            binding: .quickAssistSystemDesignContext
        ),
        .init(
            id: "quickAssistHistoryNextThread",
            title: "Quick Assist (History Next Thread)",
            shortcut: "Cmd+Option+Down",
            scope: .contextLocal,
            owner: .history,
            conflictPolicy: .disabledOutsideTarget,
            section: .quickAssist,
            persistedBindingKey: "quickAssistHistoryNextThread",
            binding: .quickAssistHistoryNextThread
        ),
        .init(
            id: "quickAssistHistoryPrevThread",
            title: "Quick Assist (History Prev Thread)",
            shortcut: "Cmd+Option+Up",
            scope: .contextLocal,
            owner: .history,
            conflictPolicy: .disabledOutsideTarget,
            section: .quickAssist,
            persistedBindingKey: "quickAssistHistoryPrevThread",
            binding: .quickAssistHistoryPrevThread
        ),
        .init(
            id: "quickAssistHistoryOpenThread",
            title: "Quick Assist (History Open Thread)",
            shortcut: "Cmd+Option+Return",
            scope: .contextLocal,
            owner: .history,
            conflictPolicy: .disabledOutsideTarget,
            section: .quickAssist,
            persistedBindingKey: "quickAssistHistoryOpenThread",
            binding: .quickAssistHistoryOpenThread
        ),
        .init(
            id: "cancelRequest",
            title: "Cancel Request",
            shortcut: "Cmd+Shift+.",
            scope: .global,
            owner: .quickAssist,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "cancelRequest",
            binding: .cancelRequest
        ),
        .init(
            id: "cycleProvider",
            title: "Switch AI Provider",
            shortcut: "Cmd+Shift+/",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "cycleProvider",
            binding: .cycleProvider
        ),
        .init(
            id: "resetSession",
            title: "Reset Session",
            shortcut: "Cmd+Shift+R",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "resetSession",
            binding: .resetSession
        ),
        .init(
            id: "openSettings",
            title: "Open Settings",
            shortcut: "Cmd+U",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "openSettings",
            binding: .openSettings
        ),
        .init(
            id: "quit",
            title: "Quit App",
            shortcut: "Cmd+E",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .quickAssist,
            persistedBindingKey: "quit",
            binding: .quit
        )
    ]
}
