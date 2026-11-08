import AppKit
import Combine
import QuartzCore

extension Notification.Name {
    static let overlayGeometryDidChange = Notification.Name("memanager.overlayGeometryDidChange")
}

final class OverlayWindow: NSPanel {

    /// Business seams injected as closures so the window plumbing does not
    /// depend on the SessionController and SessionLogger singletons directly.
    /// Defaults evaluate the identical expressions at the identical moment.
    var scrollTargetProvider: () -> ScrollTarget = {
        SessionController.shared.preferredHotkeyScrollTarget
    }
    var debugEventSink: (_ category: String, _ name: String, _ details: String) -> Void = {
        SessionLogger.shared.logDebugEvent(category: $0, name: $1, details: $2)
    }
    /// Escape asks the owner to hide the panel instead of hiding it here,
    /// so visibility state (focus targets, keyboard status) is updated by
    /// the same code path as the toggle hotkey. The default keeps the old
    /// behaviour for a window nobody wired.
    var onDismissRequested: () -> Void = {}

    enum ScrollDirection {
        case up, down
    }

    typealias AnchorEdge = OverlayWindowGeometry.AnchorEdge

    private var anchorEdge: AnchorEdge = .left
    private(set) var borderOutset: CGFloat = 0
    private var appearanceSubscription: AnyCancellable?
    private var accessibilitySubscription: AnyCancellable?
    private let borderBinding = OverlayBorderOutsetBinding()
    private var gapMousePassthrough: OverlayGapMousePassthrough?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        configureWindowBehavior()
        configureAppearance()
        switch SettingsManager.shared.overlayAnchorEdge {
        case .left:
            anchorEdge = .left
        case .right:
            anchorEdge = .right
        }
        borderOutset = CGFloat(SettingsManager.shared.configuration(for: SettingsManager.shared.borderShaderStyle)?.width ?? 0)
        applyAnchor()
        setupWindowNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window Movement & Screen Change Handling

    private func setupWindowNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func windowDidMove(_ notification: Notification) {
        notifyGeometryChanged(reason: "window_moved")
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        applyAnchor()
        updateLayerContentsScale()
        notifyGeometryChanged(reason: "window_changed_screen")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        applyAnchor()
        updateLayerContentsScale()
        notifyGeometryChanged(reason: "screen_parameters_changed")
    }

    @objc private func windowDidResize(_ notification: Notification) {
        let contentWidth = max(0, frame.width - 2 * borderOutset)
        if SettingsManager.shared.overlayWidth != contentWidth {
            SettingsManager.shared.overlayWidth = contentWidth
        }
        invalidateShadow()
        notifyGeometryChanged(reason: "window_resized")
    }

    /// Request a lightweight redraw without forcing deep layer invalidation.
    /// Aggressive recursive invalidation can blank embedded WKWebView content.
    private func invalidateLayerContent() {
        contentView?.layer?.setNeedsDisplay()
        contentView?.needsDisplay = true
    }

    /// Update layer scale to match current screen's backing scale factor
    private func updateLayerContentsScale() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor

        func updateScale(_ layer: CALayer?) {
            layer?.contentsScale = scale
            layer?.sublayers?.forEach { updateScale($0) }
        }
        updateScale(contentView?.layer)
    }

    /// The interviewer's app has nothing to hide: the window shows up in
    /// screen sharing, screenshots and Mission Control like any other. It
    /// floats above other windows so it stays beside the video call, and it
    /// can follow the interviewer into a full screen call.
    private func configureWindowBehavior() {
        self.level = .floating
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        // Allow interaction without activating the app
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false

        // Can become key window for keyboard input
        self.becomesKeyOnlyIfNeeded = true
    }

    private func configureAppearance() {
        appearance = SettingsManager.shared.overlayAppearance.nativeAppearance
        appearanceSubscription = SettingsManager.shared.$overlayAppearance
            .receive(on: RunLoop.main)
            .sink { [weak self] choice in
                self?.appearance = choice.nativeAppearance
                self?.invalidateLayerContent()
            }
        accessibilitySubscription = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.appearance = SettingsManager.shared.overlayAppearance.nativeAppearance
                self?.invalidateLayerContent()
            }

        // Transparent background for custom styling
        self.isOpaque = false
        self.backgroundColor = NSColor.clear

        // Movable by dragging anywhere
        self.isMovableByWindowBackground = false

        self.hasShadow = true

        // Title bar hidden
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
    }

    /// Configure content view layer for proper redrawing (called after contentView is set)
    func configureContentViewLayer() {
        guard let contentView = contentView else { return }
        borderBinding.bind(contentView: contentView) { [weak self] in self?.updateBorderOutset($0) }

        contentView.wantsLayer = true
        contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        if let layer = contentView.layer {
            layer.drawsAsynchronously = false
            layer.isOpaque = false
            layer.backgroundColor = CGColor.clear
        }

        // Set initial scale
        updateLayerContentsScale()
    }

    // MARK: - Window Visibility Overrides

    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Force fresh content when showing
        applyAnchor()
        invalidateLayerContent()
        updateLayerContentsScale()
        super.makeKeyAndOrderFront(sender)
        gapMousePassthrough?.refresh()
    }

    override func orderFront(_ sender: Any?) {
        applyAnchor()
        invalidateLayerContent()
        super.orderFront(sender)
        gapMousePassthrough?.refresh()
    }

    func anchor(to edge: AnchorEdge) {
        anchorEdge = edge
        SettingsManager.shared.overlayAnchorEdge = edge == .right ? .right : .left
        applyAnchor()
        notifyGeometryChanged(reason: edge == .right ? "anchor_right" : "anchor_left")
    }

    private func applyAnchor() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let width = SettingsManager.shared.overlayWidth
        let height = screenFrame.height
        let target = NSRect(x: screenFrame.origin.x, y: screenFrame.origin.y, width: width, height: height)
        let contentFrame = Self.anchoredFrame(target, in: screenFrame, edge: anchorEdge)
        let constrained = OverlayWindowGeometry.windowFrame(around: contentFrame, borderWidth: borderOutset)
        guard frame != constrained else { return }

        // Avoid forcing an immediate redraw pass while moving the panel; this can
        // cause transient WKWebView blanking until another interaction occurs.
        self.setFrame(constrained, display: false)
    }

    private func updateBorderOutset(_ width: CGFloat) {
        let width = width.isFinite ? max(0, width) : 0
        guard borderOutset != width else { return }
        borderOutset = width
        applyAnchor()
        notifyGeometryChanged(reason: "border_width")
    }

    // Content fills the usable height. The border can extend into clipped space.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? NSScreen.main else { return frameRect }
        var proposedContent = frameRect
        proposedContent.size.width -= 2 * borderOutset
        let contentFrame = Self.anchoredFrame(proposedContent, in: screen.visibleFrame, edge: anchorEdge)
        return OverlayWindowGeometry.windowFrame(around: contentFrame, borderWidth: borderOutset)
    }

    static func anchoredFrame(_ frameRect: NSRect, in screenVisibleFrame: NSRect, edge: AnchorEdge) -> NSRect {
        OverlayWindowGeometry.contentFrame(frameRect, in: screenVisibleFrame, edge: edge)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Cursor Suppression

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate:
            NSCursor.arrow.set()
        default:
            super.sendEvent(event)
        }
    }

    // Escape asks the owner to hide the window
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape key
            onDismissRequested()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Width Adjustment

    func increaseWidth(by delta: CGFloat = 50) {
        var frame = self.frame
        frame.size.width += delta
        let constrained = constrainFrameRect(frame, to: self.screen)
        setFrame(constrained, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        notifyGeometryChanged(reason: "increase_width")
    }

    func decreaseWidth(by delta: CGFloat = 50) {
        var frame = self.frame
        frame.size.width = max(400 + 2 * borderOutset, frame.size.width - delta)
        let constrained = constrainFrameRect(frame, to: self.screen)
        setFrame(constrained, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        notifyGeometryChanged(reason: "decrease_width")
    }

    private func notifyGeometryChanged(reason: String) {
        gapMousePassthrough?.refresh()
        NotificationCenter.default.post(
            name: .overlayGeometryDidChange,
            object: self,
            userInfo: ["reason": reason]
        )
    }

    func updateFloatingGlassHitRegions(_ regions: [OverlayGlassHitRegion], in view: NSView) {
        if gapMousePassthrough == nil { gapMousePassthrough = OverlayGapMousePassthrough(window: self) }
        gapMousePassthrough?.update(regions: regions, in: view)
    }

    func removeFloatingGlassHitRegions(in view: NSView) {
        gapMousePassthrough?.removeRegions(in: view)
    }

    func applyFloatingBorderOutset(_ width: CGFloat, from view: NSView) {
        borderBinding.takeOwnership(view)
        updateBorderOutset(width)
    }

    func releaseFloatingBorderOutset(from view: NSView) {
        if borderBinding.releaseOwnership(view) { configureContentViewLayer() }
    }

    // MARK: - Scroll Support

    func scrollContent(direction: ScrollDirection) {
        let delta: CGFloat = direction == .down ? 100 : -100
        let target = scrollTargetProvider()
        NSLog("[OverlayWindow] scroll request target=\(target.rawValue) delta=\(delta)")

        if ScrollCoordinator.shared.scroll(target: target, delta: delta) {
            NSLog("[OverlayWindow] scroll handled by target=\(target.rawValue)")
            return
        }

        guard let rootView = contentView else {
            NSLog("[OverlayWindow] scroll fallback unavailable: missing contentView")
            return
        }

        guard let fallback = fallbackScrollView(in: rootView, preferredTarget: target) else {
            NSLog("[OverlayWindow] scroll fallback miss target=\(target.rawValue)")
            debugEventSink("scroll", "overlay_scroll_fallback_miss", "target=\(target.rawValue)")
            return
        }

        NSLog("[OverlayWindow] scroll fallback hit target=\(target.rawValue)")
        debugEventSink(
            "scroll",
            "overlay_scroll_fallback_hit",
            "target=\(target.rawValue), scrollViewWidth=\(Int(fallback.bounds.width))"
        )
        scroll(fallback, delta: delta)
    }

    private func scroll(_ scrollView: NSScrollView, delta: CGFloat) {
        let currentY = scrollView.contentView.bounds.origin.y
        let maxY = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        let newY = max(0, min(currentY + delta, maxY - visibleHeight))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: newY))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func fallbackScrollView(in rootView: NSView, preferredTarget: ScrollTarget) -> NSScrollView? {
        OverlayScrollFallback.scrollView(in: rootView, preferredTarget: preferredTarget)
    }
}
