import XCTest
@testable import memanager

@MainActor
final class AppLaunchDecisionTests: XCTestCase {
    func testAccessibilityGrantedDoesNotRequestAccessibilityAlert() {
        let provider = StubLaunchPermissionProvider(
            current: .init(
                accessibility: .granted,
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                audioPermissionsCompleted: true
            )
        )

        let decision = determineAppLaunchDecision(permissionProvider: provider)

        XCTAssertEqual(decision.action, .registerHotkeys)
        XCTAssertFalse(decision.needsAudioPermissions)
        XCTAssertEqual(provider.refreshCallCount, 1)
    }

    func testAccessibilityDeniedRequestsAccessibilityAlert() {
        let provider = StubLaunchPermissionProvider(
            current: .init(
                accessibility: .denied,
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                audioPermissionsCompleted: true
            )
        )

        let decision = determineAppLaunchDecision(permissionProvider: provider)

        XCTAssertEqual(decision.action, .requestAccessibility)
        XCTAssertFalse(decision.needsAudioPermissions)
        XCTAssertEqual(provider.refreshCallCount, 1)
    }

    func testRefreshBeforeEvaluationPreventsFalseAccessibilityDenialOnLaunch() {
        let provider = StubLaunchPermissionProvider(
            current: .init(
                accessibility: .denied,
                microphone: .notDetermined,
                speechRecognition: .notDetermined,
                screenRecording: .granted,
                audioPermissionsCompleted: false
            ),
            refreshed: .init(
                accessibility: .granted,
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                audioPermissionsCompleted: true
            )
        )

        let decision = determineAppLaunchDecision(permissionProvider: provider)

        XCTAssertEqual(provider.refreshCallCount, 1)
        XCTAssertEqual(decision.action, .registerHotkeys)
        XCTAssertFalse(decision.needsAudioPermissions)
        XCTAssertEqual(decision.snapshot.accessibility, .granted)
    }
}

@MainActor
private final class StubLaunchPermissionProvider: AppLaunchPermissionProviding {
    struct Snapshot {
        var accessibility: PermissionStatus
        var microphone: PermissionStatus
        var speechRecognition: PermissionStatus
        var screenRecording: PermissionStatus
        var audioPermissionsCompleted: Bool
    }

    private var currentSnapshot: Snapshot
    private let refreshedSnapshot: Snapshot?
    private(set) var refreshCallCount = 0

    var accessibilityStatus: PermissionStatus { currentSnapshot.accessibility }
    var microphoneStatus: PermissionStatus { currentSnapshot.microphone }
    var speechRecognitionStatus: PermissionStatus { currentSnapshot.speechRecognition }
    var screenRecordingStatus: PermissionStatus { currentSnapshot.screenRecording }
    var audioPermissionsCompleted: Bool { currentSnapshot.audioPermissionsCompleted }

    init(current: Snapshot, refreshed: Snapshot? = nil) {
        self.currentSnapshot = current
        self.refreshedSnapshot = refreshed
    }

    func refreshAllStatuses() {
        refreshCallCount += 1
        if let refreshedSnapshot {
            currentSnapshot = refreshedSnapshot
        }
    }
}
