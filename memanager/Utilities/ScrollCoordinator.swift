import AppKit

enum ScrollTarget: String, CaseIterable {
    case main
    case transcript
    case quickAssist
    case mlGuide
}

final class ScrollCoordinator {
    static let shared = ScrollCoordinator()

    private struct WeakScrollView {
        weak var value: NSScrollView?
    }

    private var scrollViews: [ScrollTarget: WeakScrollView] = [:]

    private init() {}

    func register(_ scrollView: NSScrollView, for target: ScrollTarget) {
        let replacingExisting = scrollViews[target]?.value != nil && scrollViews[target]?.value !== scrollView
        scrollViews[target] = WeakScrollView(value: scrollView)
        // Only replacement registrations are diagnostically interesting;
        // per-registration logging previously fired on every SwiftUI update.
        if replacingExisting {
            SessionLogger.shared.logDebugEvent(
                category: "scroll",
                name: "scroll_target_replaced",
                details: "target=\(target.rawValue)"
            )
        }
    }

    /// Removes the registration only when `scrollView` is still the current
    /// holder, so a stale detach can never evict a newer registration.
    func unregister(_ scrollView: NSScrollView, for target: ScrollTarget) {
        guard scrollViews[target]?.value === scrollView else { return }
        scrollViews[target] = nil
    }

    @discardableResult
    func scroll(target: ScrollTarget, delta: CGFloat, animated: Bool = true) -> Bool {
        guard let scrollView = scrollViews[target]?.value else {
            scrollViews[target] = nil
            SessionLogger.shared.logDebugEvent(
                category: "scroll",
                name: "scroll_target_miss",
                details: "target=\(target.rawValue), delta=\(Int(delta))"
            )
            return false
        }

        let currentY = scrollView.contentView.bounds.origin.y
        let maxY = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        let newY = max(0, min(currentY + delta, maxY - visibleHeight))

        let origin = NSPoint(x: 0, y: newY)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                scrollView.contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }
}
