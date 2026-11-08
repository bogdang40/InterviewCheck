/// Readiness means an installed event tap, not just an Accessibility grant.
/// Failed attempts remain retryable and successful UI work runs exactly once.
@MainActor
final class HotkeyStartupRegistration {
    private(set) var isReady = false
    private var hasDeliveredReady = false

    @discardableResult
    func attempt(accessibilityGranted: Bool, register: () -> Bool, onReady: () -> Void) -> Bool {
        isReady = accessibilityGranted && register()
        guard isReady else { return false }
        if !hasDeliveredReady {
            hasDeliveredReady = true
            onReady()
        }
        return true
    }
}
