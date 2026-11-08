import AppKit
import Carbon.HIToolbox

/// The two shortcuts an interviewer needs while the video call is in front:
/// Question asked (Cmd+Shift+Return) and Answer done (Cmd+Shift+E).
///
/// They are Carbon hot keys: macOS delivers only these two key combinations
/// to the app, so no Accessibility permission is needed and no other
/// keystroke is ever seen. They exist only while an interview is live.
@MainActor
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    struct Shortcut: Equatable {
        let id: UInt32
        let title: String
        let display: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static let questionAsked = Shortcut(id: 1, title: "Question asked", display: "\u{21E7}\u{2318}\u{21A9}",
                                        keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | shiftKey))
    static let answerDone = Shortcut(id: 2, title: "Answer done", display: "\u{21E7}\u{2318}E",
                                     keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey))
    static let all = [questionAsked, answerDone]

    private static let enabledKey = "interviewcheck.globalShortcuts.enabled"
    private static let signature: OSType = 0x4956_434B // "IVCK"

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var failedShortcuts: [Shortcut] = []

    /// On by default; the interviewer can turn them off in Settings.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { deactivate() } else if InterviewController.shared.phase == .live { activate() }
        }
    }

    var isActive: Bool { !hotKeys.isEmpty }

    func activate() {
        guard isEnabled, hotKeys.isEmpty, !TestRuntime.isRunningUnitTests else { return }
        installHandlerIfNeeded()
        failedShortcuts = []
        for shortcut in Self.all {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: shortcut.id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
            } else {
                // Another app already owns this combination.
                failedShortcuts.append(shortcut)
            }
        }
    }

    func deactivate() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
    }

    fileprivate func fire(_ id: UInt32) {
        switch id {
        case Self.questionAsked.id: InterviewController.shared.markQuestion()
        case Self.answerDone.id: InterviewController.shared.answerDone()
        default: break
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalShortcuts.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
