import AppKit

/// The native resource boundary lets registration failures be tested without
/// installing a global keyboard hook.
protocol HotkeyEventTapControlling: AnyObject {
    var isEnabled: Bool { get }
    func install(callback: @escaping CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> Bool
    func enable()
    func invalidate()
}

final class SessionHotkeyEventTap: HotkeyEventTapControlling {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    var isEnabled: Bool {
        guard let tap, CFMachPortIsValid(tap) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func install(callback: @escaping CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> Bool {
        if isEnabled { return true }
        invalidate()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: callback, userInfo: userInfo
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        let runLoop = CFRunLoopGetMain()
        self.tap = tap
        self.source = source
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        enable()
        guard isEnabled else {
            invalidate()
            return false
        }
        return true
    }

    func enable() {
        guard let tap, CFMachPortIsValid(tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        runLoop = nil
    }

    deinit { invalidate() }
}
