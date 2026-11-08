import SwiftUI

/// Session controls reachable from the pill's popover.
struct SessionPillActions {
    let start: () -> Void
    let pauseOrResume: () -> Void
    let end: () -> Void
    let reset: () -> Void
    let screenshot: () -> Void
}

/// Pure mapping from session flags to the dot state and label.
struct SessionPillModel: Equatable {
    let state: Session.SessionState
    let isRecording: Bool
    let isLoading: Bool
    let isStreaming: Bool

    var dotState: StatusDotState {
        switch state {
        case .idle: return .idle
        case .listening: return isRecording ? .recording : .error
        case .paused: return .paused
        }
    }

    var label: String {
        switch state {
        case .idle: return "Not listening"
        case .listening: return isRecording ? "Listening" : "Capture unavailable"
        case .paused: return "Paused"
        }
    }

    var showsElapsed: Bool { state != .idle }
}

/// The session pill in the command bar: state dot, label, elapsed time,
/// and a popover with the session commands and their keys. A popover is
/// used instead of a menu because macOS flattens menu labels to text.
struct SessionStatePill: View {
    let model: SessionPillModel
    let startedAt: Date?
    let actions: SessionPillActions

    @State private var isPresentingActions = false
    @State private var isConfirmingReset = false

    var body: some View {
        Button {
            isPresentingActions.toggle()
        } label: {
            HStack(spacing: 6) {
                StatusDot(state: model.dotState, size: 7)
                Text(model.label)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                if model.showsElapsed, let startedAt {
                    ElapsedLabel(since: startedAt, isRunning: true)
                        .help("Session duration, including pauses")
                }
                Image(systemName: "chevron.down")
                    .font(OverlayType.symbol(8, weight: .bold))
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Session controls")
        .popover(isPresented: $isPresentingActions, arrowEdge: .bottom) {
            SessionActionsPopover(model: model, actions: confirmedActions) {
                isPresentingActions = false
            }
        }
        .alert("Reset the current session?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset session", role: .destructive, action: actions.reset)
        } message: {
            Text("Capture will stop and the current transcript, screenshots, and answers will be cleared from this session. Saved session history will remain.")
        }
    }

    private var confirmedActions: SessionPillActions {
        SessionPillActions(start: actions.start, pauseOrResume: actions.pauseOrResume,
            end: actions.end, reset: { isConfirmingReset = true }, screenshot: actions.screenshot)
    }
}

/// The session command list shown by the pill.
struct SessionActionsPopover: View {
    let model: SessionPillModel
    let actions: SessionPillActions
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.state == .idle {
                row("Start session", ShortcutCatalog.startSession, "mic", actions.start)
            } else {
                row(model.state == .paused ? "Resume" : "Pause", ShortcutCatalog.togglePause, model.state == .paused ? "play" : "pause", actions.pauseOrResume)
                row("End session", ShortcutCatalog.endSession, "stop", actions.end)
            }
            row("Capture screen", ShortcutCatalog.screenshot, "camera.viewfinder", actions.screenshot)
            Hairline().padding(.vertical, 4)
            row("Reset session", ShortcutCatalog.resetSession, "arrow.counterclockwise", actions.reset, tone: .critical)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: 230)
        .background(OverlayPalette.canvas.opacity(0.96))
    }

    private func row(_ title: String, _ shortcut: String, _ systemImage: String, _ action: @escaping () -> Void, tone: OverlayTone = .neutral) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(OverlayType.symbol(11))
                    .frame(width: 16)
                Text(title)
                    .font(OverlayType.callout)
                Spacer(minLength: 8)
                KeyCap(shortcut: shortcut)
            }
            .foregroundStyle(tone == .critical ? tone.color : OverlayPalette.textPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.overlayGhost)
    }
}

/// Wall-clock session duration, including pauses in capture.
struct ElapsedLabel: View {
    let since: Date
    let isRunning: Bool

    var body: some View {
        if isRunning {
            TimelineView(.periodic(from: since, by: 1)) { context in
                text(for: context.date.timeIntervalSince(since))
            }
        } else {
            text(for: Date().timeIntervalSince(since))
        }
    }

    private func text(for elapsed: TimeInterval) -> some View {
        Text(AnswerClockPolicy.label(forElapsed: elapsed))
            .font(OverlayType.monoMicro)
            .monospacedDigit()
            .foregroundStyle(OverlayPalette.textTertiary)
    }
}
