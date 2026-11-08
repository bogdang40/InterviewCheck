import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: OverlayWindow?
    private var hotkeyManager: HotkeyManager?
    private var hotkeyWiring: HotkeyActionWiring?
    private var startupIndicator: StartupIndicatorWindow?
    private var appearanceProfileSession: AppearanceProfileSession?
    private let databaseMaintenance = DatabaseMaintenanceService()
    private let permissionManager = PermissionManager.shared
    private var accessibilityPollingTimer: Timer?
    private let hotkeyStartupRegistration = HotkeyStartupRegistration()
    private var needsInitialAudioPermissions = false
    private let accessController = AccessController.shared
    private let overlayNavigator = OverlayNavigator.shared
    private var hasCompletedLaunch = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A normal app: Dock icon, visible in screen sharing and Mission Control.

        if AppearanceProfileSession.isRequested {
            appearanceProfileSession = AppearanceProfileSession()
            return
        }

        // Under XCTest this delegate belongs to the test HOST: launching the
        // real UI would register global hotkeys, start runtime timers, and,
        // when the rebuilt ad hoc binary lost its TCC grant, block the whole
        // suite behind a modal accessibility alert.
        guard !TestRuntime.isRunningUnitTests else {
            logDebug("XCTest run detected - skipping launch UI, hotkeys, and permission prompts")
            return
        }

        // Kick the database's first touch (DDL plus migrations, potentially
        // a fresh install or a schema upgrade) onto a utility queue before
        // anything on the main thread reaches for it.
        DispatchQueue.global(qos: .utility).async {
            SessionDatabase.shared.warmUp()
        }

        // Ensure the free on device speech model is installed so transcription
        // needs no API key; downloads in the background on first launch.
        SpeechAnalyzerAssetProvisioner.shared.provisionIfNeeded()

        // The sign in, paywall, and unreachable screens render inside the
        // overlay itself, so the overlay is built unconditionally and simply
        // comes up showing the gate when the account is not entitled.
        accessController.onAccessGranted = { [weak self] in
            self?.handleAccessGranted()
        }
        accessController.onAccessRevoked = { [weak self] in
            self?.handleAccessRevoked()
        }
        // Build the passive checking surface before credential I/O. A locked
        // Keychain must not prevent showing, hiding or quitting the overlay.
        completeLaunch()
        Task { @MainActor [weak self] in
            await self?.accessController.evaluate()
        }
    }

    /// Builds the overlay, hotkeys, and runtime services once.
    /// Permission and UI setup do not wait on account or Keychain I/O.
    private func completeLaunch() {
        guard !hasCompletedLaunch else { return }
        hasCompletedLaunch = true
        accessController.startPeriodicVerification()
        let launchDecision = determineAppLaunchDecision(permissionProvider: permissionManager)
        needsInitialAudioPermissions = launchDecision.needsAudioPermissions

        // Initialize hotkey manager
        hotkeyManager = HotkeyManager.shared

        // Create the main window
        setupOverlayWindow()

        // Setup hotkey actions
        setupHotkeyActions()

        // App-lifetime background work (pacing, silence evaluation) is owned
        // here, not by SessionController's binding setup.
        SessionController.shared.startRuntimeServices()
        databaseMaintenance.start()

        if !accessController.isAllowed {
            showOverlay()
        }

        // Check accessibility permissions before registering hotkeys
        if launchDecision.action == .registerHotkeys {
            if !registerHotkeysWhenReady() {
                startAccessibilityPolling()
            }
        } else {
            showAccessibilityAlert()
        }

        logDebug("App launched - Permissions: \(launchDecision.snapshot.logLine)")
    }

    // MARK: - Access gate

    /// Brings the overlay up; MentorView renders the gate in place of the
    /// shell while the account is not entitled.
    private func presentAccessGate() {
        overlayNavigator.returnToMentor()
        showOverlay(intent: .keyboardInput)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The account became entitled. During launch the launch path takes
    /// over; afterwards the user just signed in from the gate, so the
    /// overlay stays up and the shell replaces the gate in place.
    private func handleAccessGranted() {
        guard hasCompletedLaunch else { return }
        showOverlay()
    }

    /// Subscription lapsed or the account was disabled mid session: the gate
    /// takes over the overlay. Hotkeys stay registered but SessionController
    /// refuses model calls until access returns.
    private func handleAccessRevoked() {
        presentAccessGate()
    }

    /// memanager://billing/... from the Stripe return page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where accessController.handleDeepLink(url) {
            logDebug("Handled access deep link: \(url.absoluteString)")
        }
    }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !TestRuntime.isRunningUnitTests else { return false }
        recoverHotkeyRegistration()
        // Opening the installed app must remain a way back when global hotkeys
        // are unavailable, including after an Accessibility grant expires.
        showOverlay(intent: .keyboardInput)
        application.activate(ignoringOtherApps: true)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recoverHotkeyRegistration()
    }

    private func recoverHotkeyRegistration() {
        guard !TestRuntime.isRunningUnitTests, hasCompletedLaunch else { return }
        permissionManager.refreshAccessibilityStatus()
        if !registerHotkeysWhenReady() { startAccessibilityPolling() }
    }

    // MARK: - Permissions

    /// Request audio permissions (Microphone + Speech Recognition)
    private func requestAudioPermissions() {
        logDebug("Requesting audio permissions...")

        NSApp.activate(ignoringOtherApps: true)
        permissionManager.requestPermission(.microphone) { [weak self] micGranted in
            self?.logDebug("Microphone permission result: \(micGranted)")

            self?.permissionManager.requestPermission(.speechRecognition) { [weak self] speechGranted in
                self?.logDebug("Speech recognition permission result: \(speechGranted)")

                DispatchQueue.main.async {
                    self?.permissionManager.markAudioPermissionsCompletedIfReady()
                    self?.logDebug("Permission flow complete")
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        let missingCount = permissionManager.missingPermissions.count
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
            Abley needs accessibility access to register global hotkeys.

            Please grant access in System Settings > Privacy & Security > Accessibility, then return to Abley.

            \(missingCount > 1 ? "Note: \(missingCount - 1) other permission(s) may also be needed." : "")
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Accessibility settings
            permissionManager.openSettings(for: .accessibility)
            startAccessibilityPolling()
            return
        }

        NSApplication.shared.terminate(nil)
    }

    private func startAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // This actor-isolated method schedules the timer on the main run loop.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissionManager.refreshAccessibilityStatus()
                self.registerHotkeysWhenReady()
            }
        }
    }

    @discardableResult
    private func registerHotkeysWhenReady() -> Bool {
        let ready = hotkeyStartupRegistration.attempt(
            accessibilityGranted: permissionManager.accessibilityStatus.isGranted,
            register: { hotkeyManager?.registerDefaultHotkeys() ?? false }
        ) {
            showStartupIndicator()
            if needsInitialAudioPermissions {
                needsInitialAudioPermissions = false
                requestAudioPermissions()
            }
        }
        if ready {
            accessibilityPollingTimer?.invalidate()
            accessibilityPollingTimer = nil
        }
        return ready
    }

    private func showStartupIndicator() {
        startupIndicator = StartupIndicatorWindow()
        startupIndicator?.showAndFade(duration: 2.0)
    }

    // MARK: - Overlay window

    private func setupOverlayWindow() {
        let window = OverlayWindow()

        let hostingView = MousePassthroughHostingView(rootView: MentorView())
        hostingView.wantsLayer = true

        window.contentView = hostingView
        window.configureContentViewLayer() // Configure layer after content is set

        // Escape hides the overlay through the same path as the toggle
        // hotkey so SessionController's visibility state stays in sync, and
        // it is ignored while the gate is up: an LSUIElement app with a
        // hidden gate and no hotkeys would have no way back.
        window.onDismissRequested = { [weak self] in
            guard let self, self.accessController.isAllowed else { return }
            self.hideOverlay()
        }

        window.orderOut(nil) // Start hidden
        SessionController.shared.setOverlayWindowVisible(false)
        overlayWindow = window
    }

    private func setupHotkeyActions() {
        guard let hotkeyManager = hotkeyManager else { return }

        let wiring = HotkeyActionWiring(
            hotkeyManager: hotkeyManager,
            sessionFacades: SessionController.shared
        )
        wiring.prepareForTextInput = { [weak self] in
            guard let self else { return false }
            guard self.accessController.isAllowed else {
                self.presentAccessGate()
                return false
            }
            self.showOverlay(intent: .keyboardInput)
            return true
        }
        wiring.wire()
        hotkeyWiring = wiring

        wireAppDelegateHotkeys(on: hotkeyManager)
    }

    /// Hotkey callbacks that must stay here because they drive
    /// AppDelegate owned windows and overlay state.
    private func wireAppDelegateHotkeys(on hotkeyManager: HotkeyManager) {
        hotkeyManager.onToggleVisibility = { [weak self] in
            self?.toggleOverlay()
        }

        hotkeyManager.onOpenSettings = { [weak self] in
            self?.openSettings()
        }

        hotkeyManager.onScrollDown = { [weak self] in
            self?.overlayWindow?.scrollContent(direction: .down)
        }

        hotkeyManager.onScrollUp = { [weak self] in
            self?.overlayWindow?.scrollContent(direction: .up)
        }

        hotkeyManager.onIncreaseWidth = { [weak self] in
            self?.overlayWindow?.increaseWidth()
        }

        hotkeyManager.onDecreaseWidth = { [weak self] in
            self?.overlayWindow?.decreaseWidth()
        }

        hotkeyManager.onAnchorLeft = { [weak self] in
            self?.overlayWindow?.anchor(to: .left)
        }

        hotkeyManager.onAnchorRight = { [weak self] in
            self?.overlayWindow?.anchor(to: .right)
        }
    }

    private func toggleOverlay() {
        guard let window = overlayWindow else { return }
        if window.isVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    private func showOverlay(intent: OverlayPresentationIntent = .viewing) {
        guard let window = overlayWindow else { return }
        OverlayWindowPresentation(window: window).show(intent: intent)
        SessionController.shared.setOverlayWindowVisible(true)
    }

    private func hideOverlay() {
        guard let window = overlayWindow else { return }
        OverlayWindowPresentation(window: window).hide()
        SessionController.shared.setOverlayWindowVisible(false)
    }

    /// Cmd+U: Settings is a screen inside the overlay, so opening it means
    /// showing the overlay on that screen. Pressing it again on the
    /// Settings screen returns to the mentor surface.
    private func openSettings() {
        guard accessController.isAllowed else {
            presentAccessGate()
            return
        }
        overlayNavigator.toggle(.settings)
        showOverlay(intent: .keyboardInput)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appearanceProfileSession {
            appearanceProfileSession.finish()
            return
        }
        // Stop audio capture to release resources properly
        AudioCaptureService.shared.stopCapture()
        hotkeyManager?.unregisterAll()
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
        SessionController.shared.stopRuntimeServices()
        databaseMaintenance.stop()
        // Drain queued database writes (sessions, transcripts, API calls)
        // before the process dies; without this every performAsync write
        // still in the queue was silently lost on quit.
        SessionDatabase.shared.flush()
        logDebug("Application terminating - cleaned up resources")
    }

    // MARK: - Debug Logging

    private func logDebug(_ message: String) {
        NSLog("[AppDelegate] %@", message)
    }
}
