import Foundation

// MARK: - Protocol

protocol SessionFocusLoading {
    func loadFocusForNewSession() -> SessionFocusContext
}

// MARK: - Implementation

/// Loads the most recent prior debrief's `nextSessionFocus` and constructs
/// a prompt block for injection into new session context.
final class SessionFocusLoader: SessionFocusLoading {

    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func loadFocusForNewSession() -> SessionFocusContext {
        let sessions = logger.getRecentSessions(limit: 2)

        guard sessions.count >= 2 else {
            return .empty
        }

        let priorSessionId = sessions[1].id
        guard let debrief = logger.loadSessionDebrief(sessionId: priorSessionId) else {
            return .empty
        }

        let focusItems = debrief.nextSessionFocus
        guard !focusItems.isEmpty else {
            return .empty
        }

        let promptBlock = buildPromptBlock(focusItems: focusItems, drills: debrief.drills)
        return SessionFocusContext(focusItems: focusItems, promptBlock: promptBlock)
    }

    // MARK: - Prompt Construction

    private func buildPromptBlock(focusItems: [String], drills: [SessionDrill]) -> String {
        var lines = ["## Prior Session Focus"]
        lines.append("From the previous session debrief, the candidate should focus on:")

        for (index, item) in focusItems.enumerated() {
            lines.append("\(index + 1). \(item)")
        }

        let weakDrills = drills.prefix(3)
        if !weakDrills.isEmpty {
            lines.append("")
            lines.append("Practice drills from last session:")
            for drill in weakDrills {
                lines.append("- [\(drill.kind.displayLabel)] \(drill.title): \(drill.prompt)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
