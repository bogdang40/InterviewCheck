import AppKit
import Carbon
import ApplicationServices

final class HotkeyManager {
    static let shared = HotkeyManager()

    // Hotkey callbacks
    var onToggleVisibility: (() -> Void)?
    var onStartSession: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onSolve: (() -> Void)?
    var onResetSession: (() -> Void)?
    var onTogglePauseSession: (() -> Void)?
    var onEndSession: (() -> Void)?
    var onOpenTranscriptLog: (() -> Void)?
    var onNextSection: (() -> Void)?
    var onPrevSection: (() -> Void)?
    var onJumpToSection: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onScrollDown: (() -> Void)?
    var onScrollUp: (() -> Void)?
    var onIncreaseWidth: (() -> Void)?
    var onDecreaseWidth: (() -> Void)?
    var onAnchorLeft: (() -> Void)?
    var onAnchorRight: (() -> Void)?
    var onNextStep: (() -> Void)?
    var onPrevStep: (() -> Void)?
    var onNextDesignStep: (() -> Void)?
    var onPrevDesignStep: (() -> Void)?
    var onNextQuickAssistResponse: (() -> Void)?
    var onPrevQuickAssistResponse: (() -> Void)?
    var onQuickAssist: (() -> Void)?
    var onMarkCurrentSpeakerAsMe: (() -> Void)?
    var onToggleSpeakerIdMode: (() -> Void)?
    var onToggleDiagnostics: (() -> Void)?
    var onToggleTeleprompter: (() -> Void)?
    var onNextChunk: (() -> Void)?
    var onPrevChunk: (() -> Void)?
    var shouldConsumeTeleprompterHotkeys: (() -> Bool)?
    var shouldConsumeQuickAssistHistoryHotkeys: (() -> Bool)?
    var isSystemDesignSurfaceActive: (() -> Bool)?
    var shouldRouteOverlayKeyboardInput: (() -> Bool)?
    var onSolveSystemDesign: (() -> Void)?
    var onCancelRequest: (() -> Void)?
    var onCycleProvider: (() -> Void)?
    var onShowQuickAssistView: (() -> Void)?
    var onQuickAssistFollowUp: (() -> Void)?
    var onQuickAssistImplementationContext: (() -> Void)?
    var onQuickAssistSystemDesignContext: (() -> Void)?
    var onQuickAssistDeep: (() -> Void)?
    var onQuickAssistAutoSideQuestion: (() -> Void)?
    var onFocusQuickAssistQuestion: (() -> Void)?
    var onCycleQuickAssistMode: (() -> Void)?
    var onFocusQuickAssistHistorySearch: (() -> Void)?
    var onNextQuickAssistHistoryThread: (() -> Void)?
    var onPrevQuickAssistHistoryThread: (() -> Void)?
    var onOpenQuickAssistHistoryThread: (() -> Void)?
    var onCycleLiveResponseCard: (() -> Void)?
    var onPinLiveResponseCard: (() -> Void)?
    var shouldConsumeQuickAssistModeHotkeys: (() -> Bool)?
    var onPerformOverlayCommand: ((OverlayCommand) -> Bool)?

    let eventTap: any HotkeyEventTapControlling
    let bindingsLock = NSLock()

    var bindings: [String: Hotkey] = HotkeyRegistry.defaultBindings

    init(bindings: [String: Hotkey]? = nil,
         eventTap: any HotkeyEventTapControlling = SessionHotkeyEventTap()) {
        self.eventTap = eventTap
        if let bindings {
            self.bindings = bindings
        } else {
            loadBindings()
        }
    }

    // MARK: - Accessibility Permissions

    /// Checks if accessibility permissions are granted using PermissionManager
    static func checkAccessibilityPermissions() -> Bool {
        return PermissionManager.shared.accessibilityStatus.isGranted
    }

    /// Requests accessibility permissions using PermissionManager
    static func requestAccessibilityPermissions() {
        PermissionManager.shared.requestPermission(.accessibility) { _ in
            // Callback handled by PermissionManager
        }
    }

    @discardableResult
    func registerDefaultHotkeys() -> Bool {
        if eventTap.isEnabled { return true }
        NSLog("[HotkeyManager] Registering hotkeys...")
        DebugNDJSONLogger.shared.log(
            runId: "hotkey",
            hypothesisId: "H-HK",
            location: "HotkeyManager.registerDefaultHotkeys",
            message: "register_hotkeys_begin",
            data: [:]
        )
        let registered = eventTap.install(
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard registered, eventTap.isEnabled else {
            eventTap.invalidate()
            NSLog("[HotkeyManager] ERROR: Failed to create event tap. Check accessibility permissions.")
            DebugNDJSONLogger.shared.log(
                runId: "hotkey",
                hypothesisId: "H-HK",
                location: "HotkeyManager.registerDefaultHotkeys",
                message: "event_tap_failed",
                data: [:]
            )
            return false
        }

        NSLog("[HotkeyManager] Event tap created and enabled successfully")
        DebugNDJSONLogger.shared.log(
            runId: "hotkey",
            hypothesisId: "H-HK",
            location: "HotkeyManager.registerDefaultHotkeys",
            message: "event_tap_enabled",
            data: [:]
        )
        return true
    }

    func performOverlayCommand(_ command: OverlayCommand) -> Bool {
        guard let onPerformOverlayCommand else { return false }
        return onPerformOverlayCommand(command)
    }

    func unregisterAll() {
        eventTap.invalidate()
    }

    deinit { eventTap.invalidate() }

    func dispatch(_ action: (() -> Void)?) {
        guard let action else { return }
        // The event tap runs on the main run loop. Return to macOS before
        // performing UI work, which can lay out or present the overlay.
        DispatchQueue.main.async {
            action()
        }
    }

    func dispatch<T>(_ action: ((T) -> Void)?, _ value: T) {
        guard let action else { return }
        DispatchQueue.main.async {
            action(value)
        }
    }

}
