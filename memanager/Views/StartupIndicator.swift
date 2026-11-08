import AppKit
import SwiftUI

/// Floating, non activating panel that shows the launch toast in the middle
/// of the screen and fades it out after a moment. Excluded from screen
/// sharing like every other memanager window.
final class StartupIndicatorWindow: NSPanel {
    private var fadeOutWorkItem: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: StartupIndicatorView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureStealthProperties()
        configureAppearance()
        centerOnScreen()
    }

    private func configureStealthProperties() {
        sharingType = .none
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .stationary
        ]
        hidesOnDeactivate = false
    }

    private func configureAppearance() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        appearance = SettingsManager.shared.overlayAppearance.nativeAppearance
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showAndFade(duration: TimeInterval = 1.5) {
        let hostingView = NSHostingView(rootView: StartupIndicatorView())
        hostingView.frame = NSRect(origin: .zero, size: StartupIndicatorView.size)
        contentView = hostingView

        makeKeyAndOrderFront(nil)

        fadeOutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        fadeOutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.5
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1.0
        })
    }
}
