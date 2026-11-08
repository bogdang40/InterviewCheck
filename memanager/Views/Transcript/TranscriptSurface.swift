import SwiftUI

/// Full transcript surface: every line at reading size, the live state,
/// and transcription errors with their recovery actions.
struct TranscriptSurface: View {
    let rows: [TranscriptRowModel]
    let entryCount: Int
    let isRecording: Bool
    let error: TranscriptionError?
    let fontSize: CGFloat
    let useSourceBasedIdentification: Bool
    let onSpeakerTapped: (Int) -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void
    let onDismissError: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SurfaceHeader(
                "Transcript",
                systemImage: "waveform",
                subtitle: subtitle,
                count: entryCount
            ) {
                Button("Back to answers", action: onClose)
                    .buttonStyle(.overlay(.ghost, size: .small))
                    .help("Return to the previous surface")
            }

            if let error {
                TranscriptionErrorBanner(
                    error: error,
                    onOpenSettings: onOpenSettings,
                    onRetry: onRetry,
                    onDismiss: onDismissError
                )
            }

            if rows.isEmpty {
                OverlayEmptyState(
                    systemImage: "waveform",
                    title: isRecording ? "Listening" : "No transcript yet",
                    message: isRecording
                        ? "Lines appear here as people speak. The other party's questions are marked."
                        : "Start a session and the conversation is captured here, with the other party's questions marked.",
                    hints: isRecording ? [] : [("Start session", ShortcutCatalog.startSession)]
                )
            } else {
                TranscriptList(
                    rows: rows,
                    density: .regular,
                    fontSize: fontSize,
                    scrollTarget: .transcript,
                    useSourceBasedIdentification: useSourceBasedIdentification,
                    onSpeakerTapped: onSpeakerTapped
                )
            }
        }
        .padding(OverlayLayout.stageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        isRecording ? "Live" : "Not recording"
    }
}

/// Transcription failure with its recovery actions.
struct TranscriptionErrorBanner: View {
    let error: TranscriptionError
    let onOpenSettings: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    private var supportsRetry: Bool {
        switch error {
        case .systemAudioSilent, .systemStreamStalled, .sourceBasedPipelineUnavailable:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ToneBanner(
            tone: .warning,
            title: error.errorDescription ?? "Transcription problem",
            message: error.recoverySuggestion ?? "Check the audio settings and try again.",
            actions: actions,
            onDismiss: onDismiss
        )
    }

    private var actions: [BannerAction] {
        var actions: [BannerAction] = []
        if error.systemSettingsURL != nil {
            actions.append(BannerAction(title: "Open Settings", kind: .secondary, action: onOpenSettings))
        }
        if supportsRetry {
            actions.append(BannerAction(title: "Retry stream", kind: .ghost, action: onRetry))
        }
        return actions
    }
}
