import AppKit
import SwiftUI

final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    /// Identity seam: evaluates the current session id at call time without
    /// this service depending on the whole SessionController. Tests can swap
    /// in a fixed id.
    var sessionIdentityProvider: () -> UUID

    @Published var screenshots: [Screenshot] = []
    @Published var isCapturing = false
    @Published var lastError: ScreenshotError?

    private var selectionWindow: NSWindow?
    // Resolve only after capture guards so test initialization cannot trigger
    // PermissionManager's automatic system permission refresh.
    var permissionManager: PermissionManager { .shared }

    // Image compression settings for faster uploads
    let maxImageDimension: CGFloat = 1920  // Max width or height
    let jpegQuality: CGFloat = 0.8         // 80% quality = good balance

    let captureState = ScreenshotCaptureState()
    let manualCaptureRecorder: (Screenshot, UUID) -> Void

    init(
        sessionIdentityProvider: @escaping () -> UUID = { SessionController.shared.session.id },
        manualCaptureRecorder: @escaping (Screenshot, UUID) -> Void = ScreenshotService.recordManualCapture
    ) {
        self.sessionIdentityProvider = sessionIdentityProvider
        self.manualCaptureRecorder = manualCaptureRecorder
    }

    // MARK: - Screenshot Errors

    enum ScreenshotError: LocalizedError {
        case permissionDenied
        case captureFailure
        case noScreen

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording Permission Required"
            case .captureFailure: return "Failed to Capture Screenshot"
            case .noScreen: return "No Screen Available"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .permissionDenied:
                return "Grant screen recording access in System Settings > Privacy & Security > Screen Recording"
            case .captureFailure:
                return "Try again or restart the application"
            case .noScreen:
                return "Ensure a display is connected"
            }
        }
    }

    enum FreshCaptureFailureReason: String {
        case permissionDenied
        case captureFailure
        case noScreen
    }

    struct FreshCaptureResult {
        let base64: String?
        let failureReason: FreshCaptureFailureReason?

        var succeeded: Bool {
            base64 != nil
        }
    }

    // MARK: - Permission Check

    func checkPermission() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                permissionManager.refreshAllStatuses()
                return permissionManager.screenRecordingStatus.isGranted
            }
        }

        var granted = false
        DispatchQueue.main.sync {
            granted = MainActor.assumeIsolated {
                permissionManager.refreshAllStatuses()
                return permissionManager.screenRecordingStatus.isGranted
            }
        }
        return granted
    }

    func openPermissionSettings() {
        guard !TestRuntime.isRunningUnitTests else { return }
        permissionManager.openSettings(for: .screenRecording)
    }

    // MARK: - Capture Methods

    func captureFullScreen() {
        guard !TestRuntime.isRunningUnitTests else { return }
        let identity = captureState.identity(sessionID: sessionIdentityProvider())
        // Check screen recording permission first
        guard checkPermission() else {
            logDebug("Screen recording permission denied")
            publishCaptureError(.permissionDenied, identity: identity)
            // Open settings to help user grant permission
            openPermissionSettings()
            return
        }

        guard let screen = NSScreen.main, let screenRect = ScreenCaptureGeometry.displayRect(for: screen) else {
            publishCaptureError(.noScreen, identity: identity)
            return
        }

        guard let cgImage = CGWindowListCreateImage(
            screenRect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            logDebug("CGWindowListCreateImage failed")
            publishCaptureError(.captureFailure, identity: identity)
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: screen.frame.size)
        let screenshot = Screenshot(image: nsImage, capturedAt: Date())

        publishManualScreenshot(screenshot, identity: identity)
    }

    func captureRegion() {
        guard !TestRuntime.isRunningUnitTests else { return }
        let identity = captureState.identity(sessionID: sessionIdentityProvider())
        // Check screen recording permission first
        guard checkPermission() else {
            logDebug("Screen recording permission denied for region capture")
            publishCaptureError(.permissionDenied, identity: identity)
            openPermissionSettings()
            return
        }

        guard !isCapturing else { return }
        isCapturing = true

        // Create fullscreen transparent window for region selection
        guard let screen = NSScreen.main, let screenRect = ScreenCaptureGeometry.displayRect(for: screen) else {
            isCapturing = false
            publishCaptureError(.noScreen, identity: identity)
            return
        }

        selectionWindow = RegionSelectionWindow(screen: screen) { [weak self] rect in
            guard let self, self.acceptsCapture(identity) else { return }
            self.dismissSelectionWindow()
            self.captureRect(rect, displayRect: screenRect, identity: identity)
        } onCancel: { [weak self] in
            guard let self, self.acceptsCapture(identity) else { return }
            self.dismissSelectionWindow()
        }

        selectionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func captureRect(_ rect: NSRect, displayRect: CGRect, identity: ScreenshotCaptureState.Identity) {
        guard !TestRuntime.isRunningUnitTests else { return }
        guard acceptsCapture(identity) else { return }
        guard let captureRect = ScreenCaptureGeometry.region(rect, in: displayRect) else {
            lastError = .captureFailure
            return
        }

        // Capture the screen region
        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            lastError = .captureFailure
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: captureRect.size)
        let screenshot = Screenshot(image: nsImage, capturedAt: Date())

        publishManualScreenshot(screenshot, identity: identity)
    }

    private func dismissSelectionWindow() {
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        isCapturing = false
    }

    func removeScreenshot(at index: Int) {
        guard screenshots.indices.contains(index) else { return }
        screenshots.remove(at: index)
    }

    func clearAll() {
        captureState.invalidate()
        dismissSelectionWindow()
        screenshots.removeAll()
    }

    func getBase64Images() -> [String] {
        screenshots.compactMap { screenshot in
            // Use compressed JPEG for much smaller payloads
            imageToCompressedBase64(screenshot.image)
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[ScreenshotService] \(message)")
        #endif
    }
}
