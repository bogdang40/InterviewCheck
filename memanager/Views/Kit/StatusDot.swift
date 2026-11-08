import SwiftUI

/// Live state of the session as a single dot. Active states breathe so the
/// user can confirm the microphone or the stream is alive at a glance.
enum StatusDotState: Equatable {
    case idle
    case listening
    case recording
    case paused
    case processing
    case streaming
    case ready
    case error

    var color: Color {
        switch self {
        case .idle: return OverlayPalette.textTertiary
        case .listening: return OverlayPalette.textSecondary
        case .recording: return OverlayTone.critical.color
        case .paused: return OverlayTone.warning.color
        case .processing, .streaming: return OverlayPalette.accent
        case .ready: return OverlayTone.success.color
        case .error: return OverlayTone.warning.color
        }
    }

    var isAnimated: Bool {
        switch self {
        case .recording, .processing, .streaming: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .processing: return "Thinking"
        case .streaming: return "Streaming"
        case .ready: return "Ready"
        case .error: return "Attention"
        }
    }
}

struct StatusDot: View {
    let state: StatusDotState
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.isAnimated && !reduceMotion {
                OverlayAmbientAnimation(animation: .easeOut(duration: 1.4).repeatForever(autoreverses: false)) { phase in
                    Circle()
                        .fill(state.color.opacity(0.35))
                        .frame(width: size * 2, height: size * 2)
                        .scaleEffect(phase ? 1.0 : 0.6)
                        .opacity(phase ? 0.0 : 0.8)
                }
            }
            Circle()
                .fill(state.color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityLabel(state.label)
    }
}
