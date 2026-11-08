import AVFoundation
import AppKit
import SwiftUI

/// The wizard's steps in order of appearance.
enum EnrollmentStep: Equatable {
    case instructions
    case preparing
    case recording
    case exporting
    case completed
    case error
}

/// Fixed state for previews and render tests: the step to show and whether
/// the microphone counts as granted. Disables permission prompts and audio
/// capture so the wizard can be drawn anywhere.
struct EnrollmentWizardPreview {
    let step: EnrollmentStep
    var micPermissionGranted = true
}

/// Sheet that walks through voice enrollment: instructions, recording,
/// then a completed or failed outcome.
struct EnrollmentWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var enrollmentService: VoiceSignatureEnrollmentService

    @State private var currentStep: EnrollmentStep
    @State private var micPermissionGranted: Bool
    @State private var startError: String?
    private let isPreview: Bool

    static let sheetSize = CGSize(width: 480, height: 580)

    init(enrollmentService: VoiceSignatureEnrollmentService, preview: EnrollmentWizardPreview? = nil) {
        self.enrollmentService = enrollmentService
        _currentStep = State(initialValue: preview?.step ?? .instructions)
        _micPermissionGranted = State(initialValue: preview?.micPermissionGranted ?? false)
        isPreview = preview != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader("Voice enrollment", systemImage: "waveform.badge.mic") {
                Button("Cancel") {
                    enrollmentService.cancelEnrollment()
                    dismiss()
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Hairline()

            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(["Prepare", "Record", "Finish"].enumerated()), id: \.offset) { index, title in
                    Text("\(index + 1)  \(title)")
                        .font(OverlayType.caption)
                        .foregroundStyle(index == phaseIndex ? OverlayPalette.accent : OverlayPalette.textSecondary)
                    if index < 2 { Spacer(minLength: 0) }
                }
            }
            .padding(DesignTokens.Spacing.lg)

            ScrollView {
                stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DesignTokens.Spacing.lg)
                .animation(DesignTokens.Motion.surfaceSwap, value: currentStep)
            }
        }
        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
        .background(OverlayPalette.readingSurface)
        .onReceive(enrollmentService.$state) { state in
            handleStateChange(state)
        }
        .onAppear {
            if !isPreview { checkMicPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isPreview { checkMicPermission() }
        }
        .onDisappear { if !isPreview { enrollmentService.cancelEnrollment() } }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .instructions:
            EnrollmentInstructionsStep(micPermissionGranted: micPermissionGranted, onStart: startEnrollment,
                                       onRequestPermission: requestMicPermission, onOpenPermissions: openPermissions)
        case .preparing:
            ProgressCaption(text: "Preparing voice enrollment")
        case .recording:
            EnrollmentRecordingStep(enrollmentService: enrollmentService, capturesAudio: !isPreview, onCancel: {
                enrollmentService.cancelEnrollment()
                currentStep = .instructions
            }, onFailure: { message in startError = message; currentStep = .error })
        case .exporting:
            ProgressCaption(text: "Saving the voice profile")
        case .completed:
            EnrollmentCompletedStep { dismiss() }
        case .error:
            EnrollmentErrorStep(
                error: enrollmentErrorMessage,
                onRetry: {
                    enrollmentService.cancelEnrollment()
                    startError = nil
                    currentStep = .instructions
                    checkMicPermission()
                },
                onDismiss: { dismiss() }
            )
        }
    }

    private var enrollmentErrorMessage: String {
        if let startError { return startError }
        if case .failed(let message) = enrollmentService.state {
            return message
        }
        return "An unknown error occurred."
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func requestMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { micPermissionGranted = granted }
            }
        default:
            openPermissions()
        }
    }

    private func startEnrollment() {
        guard micPermissionGranted else { return }
        startError = nil
        do {
            try enrollmentService.startEnrollment()
            currentStep = .recording
        } catch {
            startError = error.localizedDescription
            currentStep = .error
        }
    }

    private func handleStateChange(_ state: EnrollmentState) {
        guard !isPreview else { return }
        switch state {
        case .preparing: currentStep = .preparing
        case .enrolling: currentStep = .recording
        case .exporting: currentStep = .exporting
        case .completed: currentStep = .completed
        case .failed: currentStep = .error
        default: break
        }
    }

    private var phaseIndex: Int {
        switch currentStep {
        case .instructions, .preparing: return 0
        case .recording: return 1
        case .exporting, .completed, .error: return 2
        }
    }

    private func openPermissions() {
        PermissionManager.shared.openSettings(for: .microphone)
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    EnrollmentWizardView(enrollmentService: VoiceSignatureEnrollmentService())
}
#endif
