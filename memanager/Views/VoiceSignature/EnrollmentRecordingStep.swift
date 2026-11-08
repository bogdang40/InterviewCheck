import AVFoundation
import SwiftUI

/// Second step: the microphone runs, the ring fills, and the service's
/// feedback is echoed as a banner. Audio capture can be disabled so the
/// step can be rendered without a microphone.
struct EnrollmentRecordingStep: View {
    @ObservedObject var enrollmentService: VoiceSignatureEnrollmentService
    var capturesAudio: Bool = true
    let onCancel: () -> Void
    let onFailure: (String) -> Void

    @State private var tap = MicrophoneTap()
    @State private var captureError: String?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            EnrollmentProgressRing(progress: enrollmentService.progress)

            VoiceLevelMeter(level: enrollmentService.audioLevel)
                .frame(maxWidth: 240)

            Text("Speak naturally. The ring fills as your voice is captured.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .multilineTextAlignment(.center)

            if let feedback = enrollmentService.feedback {
                ToneBanner(
                    tone: feedback.isActionRequired ? .warning : .success,
                    message: feedback.message
                )
            }

            if let captureError {
                ToneBanner(tone: .critical, message: captureError)
            }

            Spacer(minLength: 0)

            Button("Cancel") {
                stopAudioCapture()
                onCancel()
            }
            .buttonStyle(.overlayGhost)
        }
        .onAppear(perform: startAudioCapture)
        .onDisappear(perform: stopAudioCapture)
    }

    private func startAudioCapture() {
        guard capturesAudio, !tap.isRunning,
              let consumeAudio = enrollmentService.makeAudioConsumer() else { return }
        do {
            try tap.start(handler: consumeAudio)
        } catch {
            let message = "Could not start the microphone: \(error.localizedDescription)"
            captureError = message
            stopAudioCapture()
            enrollmentService.cancelEnrollment()
            onFailure(message)
        }
    }

    private func stopAudioCapture() {
        tap.stop()
    }
}
