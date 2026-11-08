import Foundation

@MainActor
protocol AppLaunchPermissionProviding: AnyObject {
    var accessibilityStatus: PermissionStatus { get }
    var microphoneStatus: PermissionStatus { get }
    var speechRecognitionStatus: PermissionStatus { get }
    var screenRecordingStatus: PermissionStatus { get }
    var audioPermissionsCompleted: Bool { get }
    func refreshAllStatuses()
}

extension PermissionManager: AppLaunchPermissionProviding {}

enum AppLaunchAction: Equatable {
    case registerHotkeys
    case requestAccessibility
}

struct AppLaunchPermissionSnapshot: Equatable {
    let accessibility: PermissionStatus
    let microphone: PermissionStatus
    let speechRecognition: PermissionStatus
    let screenRecording: PermissionStatus
    let audioPermissionsCompleted: Bool

    var logLine: String {
        "Accessibility=\(accessibility.displayText), Mic=\(microphone.displayText), Speech=\(speechRecognition.displayText), Screen=\(screenRecording.displayText), AudioCompleted=\(audioPermissionsCompleted)"
    }
}

struct AppLaunchDecision: Equatable {
    let action: AppLaunchAction
    let needsAudioPermissions: Bool
    let snapshot: AppLaunchPermissionSnapshot
}

@MainActor
func determineAppLaunchDecision(
    permissionProvider: AppLaunchPermissionProviding
) -> AppLaunchDecision {
    permissionProvider.refreshAllStatuses()

    let snapshot = AppLaunchPermissionSnapshot(
        accessibility: permissionProvider.accessibilityStatus,
        microphone: permissionProvider.microphoneStatus,
        speechRecognition: permissionProvider.speechRecognitionStatus,
        screenRecording: permissionProvider.screenRecordingStatus,
        audioPermissionsCompleted: permissionProvider.audioPermissionsCompleted
    )

    let audioReady = snapshot.microphone.isGranted && snapshot.speechRecognition.isGranted
    let needsAudioPermissions = !audioReady || !snapshot.audioPermissionsCompleted
    let action: AppLaunchAction = snapshot.accessibility.isGranted ? .registerHotkeys : .requestAccessibility

    return AppLaunchDecision(
        action: action,
        needsAudioPermissions: needsAudioPermissions,
        snapshot: snapshot
    )
}

