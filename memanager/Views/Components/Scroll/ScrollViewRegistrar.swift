import SwiftUI
import AppKit

/// Registers the enclosing NSScrollView with ScrollCoordinator when the
/// helper view actually attaches to a window, and unregisters on detach.
///
/// Replaces the polling resolver that scheduled three delayed hierarchy
/// walks on EVERY SwiftUI update pass; registration is now driven by the
/// one AppKit event that matters, with a single fallback retry for the case
/// where the scroll view is not yet wired at attach time.
struct ScrollViewRegistrar: NSViewRepresentable {
    let target: ScrollTarget
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> RegistrarView {
        let view = RegistrarView()
        view.configure(target: target, isActive: isEnabled)
        return view
    }

    func updateNSView(_ nsView: RegistrarView, context: Context) {
        nsView.configure(target: target, isActive: isEnabled)
    }

    final class RegistrarView: NSView {
        private var target: ScrollTarget?
        private var isActive = false
        private weak var registeredScrollView: NSScrollView?

        func configure(target: ScrollTarget, isActive: Bool) {
            guard self.target != target || self.isActive != isActive else { return }
            unregisterIfNeeded()
            self.target = target
            self.isActive = isActive
            attemptRegistration(allowRetry: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                unregisterIfNeeded()
                return
            }
            attemptRegistration(allowRetry: true)
        }

        func attemptRegistration(allowRetry: Bool) {
            guard isActive, let target, window != nil else { return }
            if let scrollView = EnclosingScrollViewLocator.locate(around: self) {
                registeredScrollView = scrollView
                ScrollCoordinator.shared.register(scrollView, for: target)
            } else if allowRetry {
                DispatchQueue.main.async { [weak self] in
                    self?.attemptRegistration(allowRetry: false)
                }
            }
        }

        private func unregisterIfNeeded() {
            guard let target, let registeredScrollView else { return }
            ScrollCoordinator.shared.unregister(registeredScrollView, for: target)
            self.registeredScrollView = nil
        }
    }
}
