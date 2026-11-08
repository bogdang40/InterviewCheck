import AppKit

extension HotkeyRegistry {
    static let sessionEntries: [HotkeyRegistryEntry] = [
        .init(
            id: "toggleVisibility",
            title: "Toggle Visibility",
            shortcut: "Cmd+D",
            scope: .global,
            owner: .overlayShell,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "toggleVisibility",
            binding: .toggleVisibility
        ),
        .init(
            id: "startSession",
            title: "New Interview",
            shortcut: "Cmd+Shift+S",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "startSession",
            binding: .startSession
        ),
        .init(
            id: "togglePause",
            title: "Pause/Resume Session",
            shortcut: "Cmd+Shift+P",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "togglePause",
            binding: .togglePause
        ),
        .init(
            id: "endSession",
            title: "Answer Done",
            shortcut: "Cmd+Shift+E",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "endSession",
            binding: .endSession
        ),
        .init(
            id: "openTranscriptLog",
            title: "Open Transcript Log",
            shortcut: "Cmd+Shift+T",
            scope: .global,
            owner: .transcript,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "openTranscriptLog",
            binding: .openTranscriptLog
        ),
        .init(
            id: "toggleDiagnostics",
            title: "Toggle Diagnostics",
            shortcut: "Cmd+Shift+D",
            scope: .global,
            owner: .diagnostics,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "toggleDiagnostics",
            binding: .toggleDiagnostics
        ),
        .init(
            id: "markCurrentSpeaker",
            title: "Mark Current Speaker as Me",
            shortcut: "Cmd+Shift+M",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "markCurrentSpeaker",
            binding: .markCurrentSpeaker
        ),
        .init(
            id: "toggleSpeakerIdMode",
            title: "Toggle Speaker ID Mode",
            shortcut: "Cmd+Shift+I",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "toggleSpeakerIdMode",
            binding: .toggleSpeakerIdMode
        ),
        .init(
            id: "screenshot",
            title: "Screenshot",
            shortcut: "Cmd+Shift+X",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "screenshot",
            binding: .screenshot
        ),
        .init(
            id: "solve",
            title: "Question Asked",
            shortcut: "Cmd+Shift+Return",
            scope: .global,
            owner: .session,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "solve",
            binding: .solve
        ),
        .init(
            id: "solveSystemDesign",
            title: "Solve System Design",
            shortcut: "Cmd+Shift+Y",
            scope: .global,
            owner: .systemDesign,
            conflictPolicy: .exclusive,
            section: .session,
            persistedBindingKey: "solveSystemDesign",
            binding: .solveSystemDesign
        )
    ]
}
