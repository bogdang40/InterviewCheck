import SwiftUI

/// Whether each side of the call is actually reaching the detector.
struct AudioStatusModel: Equatable {
    enum Level: Equatable { case ok, waiting, problem }

    struct Side: Equatable {
        let title: String
        let detail: String
        let level: Level
    }

    let mic: Side
    let call: Side

    /// Audio buffers older than this mean a stream has stopped.
    static let staleAfter: TimeInterval = 5

    var hasProblem: Bool { mic.level == .problem || call.level == .problem }

    init(
        isRecording: Bool,
        micState: DeepgramConnectionState,
        callState: DeepgramConnectionState,
        isCallAudioActive: Bool,
        micLastBuffer: Date?,
        callLastBuffer: Date?,
        now: Date
    ) {
        mic = Self.side(title: "Your mic", recording: isRecording, state: micState, capturing: true,
                        lastBuffer: micLastBuffer, now: now, silentHint: "No sound from the microphone")
        call = Self.side(title: "Call audio", recording: isRecording, state: callState, capturing: isCallAudioActive,
                         lastBuffer: callLastBuffer, now: now,
                         silentHint: "No sound from the call. Is the call playing on this Mac?")
    }

    private static func side(
        title: String, recording: Bool, state: DeepgramConnectionState, capturing: Bool,
        lastBuffer: Date?, now: Date, silentHint: String
    ) -> Side {
        guard recording else { return Side(title: title, detail: "Starting\u{2026}", level: .waiting) }
        if !capturing {
            return Side(title: title, detail: "Not recording. Check Screen & System Audio Recording in System Settings.",
                        level: .problem)
        }
        switch state {
        case .error(let message):
            return Side(title: title, detail: "Transcription error: \(message)", level: .problem)
        case .connecting:
            return Side(title: title, detail: "Connecting\u{2026}", level: .waiting)
        case .disconnected:
            return Side(title: title, detail: "Disconnected", level: .problem)
        case .connected:
            if let lastBuffer, now.timeIntervalSince(lastBuffer) > staleAfter {
                return Side(title: title, detail: "\(silentHint) (\(Int(now.timeIntervalSince(lastBuffer))) s)",
                            level: .problem)
            }
            return Side(title: title, detail: "Connected", level: .ok)
        }
    }
}

/// The two connection lights and the interview clock, refreshed each second.
struct AudioStatusStrip: View {
    @ObservedObject private var audio = AudioCaptureService.shared
    let startedAt: Date?
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let model = AudioStatusModel(
                isRecording: audio.isRecording,
                micState: audio.deepgramMicState,
                callState: audio.deepgramSystemState,
                isCallAudioActive: audio.isSystemAudioActive,
                micLastBuffer: audio.micBufferLastTime,
                callLastBuffer: audio.systemBufferLastTime,
                now: context.date
            )
            HStack(spacing: 14) {
                light(model.mic)
                light(model.call)
                if let startedAt, !compact {
                    Spacer(minLength: 0)
                    Label(Duration.seconds(context.date.timeIntervalSince(startedAt))
                            .formatted(.time(pattern: .minuteSecond)), systemImage: "clock")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private func light(_ side: AudioStatusModel.Side) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(side.level)).frame(width: 8, height: 8)
            Text(compact ? side.title : "\(side.title): \(side.detail)")
                .lineLimit(1)
                .foregroundStyle(side.level == .problem ? .red : .primary)
        }
        .help("\(side.title): \(side.detail)")
        .accessibilityElement(children: .combine)
    }

    private func color(_ level: AudioStatusModel.Level) -> Color {
        switch level {
        case .ok: return .green
        case .waiting: return .orange
        case .problem: return .red
        }
    }
}
