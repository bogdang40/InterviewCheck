import AVFoundation
import Foundation
import Speech

/// Transcript, permissions, and error rows.
@MainActor
struct DiagnosticsSystemReport {
    let audioService: AudioCaptureService
    let permissionManager: PermissionManager
    let controller: SessionController

    var transcriptGroup: DiagnosticsGroup {
        DiagnosticsGroup(title: "Transcript", systemImage: "text.quote", rows: [
            DiagnosticsRow(label: "Entries", value: "\(audioService.transcriptEntries.count)"),
            DiagnosticsRow(label: "Characters", value: "\(audioService.transcript.count)"),
            DiagnosticsRow(label: "Partial Me", value: "\(audioService.partialMe.count)"),
            DiagnosticsRow(label: "Partial Other", value: "\(audioService.partialOther.count)")
        ])
    }

    var permissionsGroup: DiagnosticsGroup {
        DiagnosticsGroup(title: "Permissions", systemImage: "lock.shield", rows: [
            DiagnosticsRow(label: "Accessibility", value: permissionManager.accessibilityStatus.displayText),
            DiagnosticsRow(label: "Microphone", value: permissionManager.microphoneStatus.displayText),
            DiagnosticsRow(label: "Speech", value: permissionManager.speechRecognitionStatus.displayText),
            DiagnosticsRow(label: "Screen", value: permissionManager.screenRecordingStatus.displayText),
            DiagnosticsRow(label: "Mic (OS)", value: DiagnosticsValueFormatter.authorization(AVCaptureDevice.authorizationStatus(for: .audio))),
            DiagnosticsRow(label: "Speech (OS)", value: DiagnosticsValueFormatter.speechAuthorization(SFSpeechRecognizer.authorizationStatus()))
        ])
    }

    var errorsGroup: DiagnosticsGroup {
        DiagnosticsGroup(title: "Errors", systemImage: "exclamationmark.triangle", rows: [
            DiagnosticsRow(label: "Audio Error", value: audioService.errorMessage ?? "none"),
            DiagnosticsRow(label: "Transcription", value: audioService.transcriptionError?.errorDescription ?? "none"),
            DiagnosticsRow(label: "Recovery", value: audioService.transcriptionError?.recoverySuggestion ?? "n/a"),
            DiagnosticsRow(label: "Session", value: controller.errorMessage ?? "none")
        ])
    }
}
