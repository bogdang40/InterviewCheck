import SwiftUI

/// The mentor screen: live strip, chrome banners, and the active surface
/// (Assist, Solve, Design, or Transcript). Surface choice is derived from
/// SessionController's flags by `MentorSurfaceResolver`.
struct MentorStage: View {
    @ObservedObject var controller = SessionController.shared
    @ObservedObject var audioService = AudioCaptureService.shared
    @ObservedObject var screenshotService = ScreenshotService.shared
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var voiceStore = VoiceSignatureStore.shared
    @Environment(\.overlayContentIsVisible) private var isContentVisible

    let width: CGFloat
    @State private var visitedSurfaces: Set<MentorSurface> = []

    private var surface: MentorSurface {
        MentorSurfaceResolver(
            isQuickAssistVisible: controller.isQuickAssistViewVisible,
            isTranscriptVisible: controller.isTranscriptViewVisible,
            currentSection: controller.currentSection
        ).surface
    }

    private var liveQuestion: LiveQuestion? {
        LiveQuestionResolver.resolve(
            entries: audioService.transcriptEntries,
            partialOther: audioService.partialOther,
            partialOtherSpeaker: audioService.partialOtherSpeaker
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if surface != .transcript && surface != .assist {
                LiveStrip(
                    question: liveQuestion,
                    pacing: PacingBadgeModel(state: controller.pacingState, enabled: settings.pacingDirectorEnabled),
                    onAnswer: { controller.triggerQuickAssist() }
                )
            }

            MentorChromeBanners()

            surfaceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(DesignTokens.Motion.surfaceSwap, value: surface)
        }
        .onAppear { visitedSurfaces.insert(surface) }
        .onChange(of: surface) { previous, current in
            visitedSurfaces.insert(previous)
            visitedSurfaces.insert(current)
        }
    }

    private var surfaceContent: some View {
        ZStack {
            ForEach(MentorSurface.allCases) { candidate in
                if visitedSurfaces.contains(candidate) || candidate == surface {
                    content(for: candidate)
                        .environment(\.overlayContentIsVisible, isContentVisible && candidate == surface)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(candidate == surface ? 1 : 0)
                        .allowsHitTesting(candidate == surface)
                        .disabled(candidate != surface)
                        .accessibilityHidden(candidate != surface)
                        .zIndex(candidate == surface ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for candidate: MentorSurface) -> some View {
        switch candidate {
        case .assist:
            QuickAssistStudioView(state: quickAssistStudioState, actions: quickAssistStudioActions)
                .transition(.opacity)
        case .transcript:
            TranscriptSurface(
                rows: TranscriptRowsBuilder.rows(
                    entries: audioService.transcriptEntries,
                    partialMe: audioService.partialMe,
                    partialOther: audioService.partialOther,
                    partialOtherSpeaker: audioService.partialOtherSpeaker,
                    limit: nil
                ),
                entryCount: audioService.transcriptEntries.count,
                isRecording: audioService.isRecording,
                error: audioService.transcriptionError,
                fontSize: settings.fontSize,
                useSourceBasedIdentification: voiceStore.useSourceBasedIdentification,
                onSpeakerTapped: { audioService.markSpeakerAsMe($0) },
                onOpenSettings: { audioService.openSystemSettings() },
                onRetry: { audioService.retrySystemStream() },
                onDismissError: { audioService.clearError() },
                onClose: { controller.hideTranscriptLog() }
            )
            .transition(.opacity)
        case .design:
            DesignSurface(width: width)
                .transition(.opacity)
        case .solve:
            SolveSurface(width: width)
                .transition(.opacity)
        }
    }
}
