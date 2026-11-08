import SwiftUI

/// Empty Solve surface, phrased for the session state the user is in.
struct SolveEmptyState: View {
    let state: Session.SessionState
    let onStart: () -> Void
    let onSolve: () -> Void
    let onScreenshot: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        switch state {
        case .idle:
            OverlayEmptyState(
                systemImage: "sparkles",
                title: "Ready when you are",
                message: "Start a session to capture the conversation and your screen. Solve turns the problem into a walkthrough you can narrate.",
                primary: EmptyStateAction(title: "Start session", shortcut: ShortcutCatalog.startSession, action: onStart),
                secondary: EmptyStateAction(title: "Capture screen", shortcut: ShortcutCatalog.screenshot, action: onScreenshot),
                hints: [("Solve", ShortcutCatalog.solve)],
                pulses: true
            )
        case .listening:
            OverlayEmptyState(
                systemImage: "mic",
                title: "Listening",
                message: "Read the problem aloud or capture the screen, then solve. The answer arrives section by section as it streams.",
                primary: EmptyStateAction(title: "Solve", shortcut: ShortcutCatalog.solve, action: onSolve),
                secondary: EmptyStateAction(title: "Capture screen", shortcut: ShortcutCatalog.screenshot, action: onScreenshot),
                pulses: true
            )
        case .paused:
            OverlayEmptyState(
                systemImage: "pause",
                title: "Paused",
                message: "The microphone is off. Resume when the conversation picks back up, or end the session to file it.",
                primary: EmptyStateAction(title: "Resume", shortcut: ShortcutCatalog.togglePause, action: onResume),
                secondary: EmptyStateAction(title: "End session", shortcut: ShortcutCatalog.endSession, action: onEnd)
            )
        }
    }
}
