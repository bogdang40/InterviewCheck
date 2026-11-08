import AppKit

/// Belt-and-suspenders cursor suppression layer. Installs a local
/// event monitor that forces the arrow cursor on every mouse-move,
/// catching any cursor change SwiftUI's hosting view tries to push.
final class StealthCursorGuard {
    static let shared = StealthCursorGuard()

    private var monitor: Any?

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            NSCursor.arrow.set()
            return event
        }
    }

    func uninstall() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
