import AppKit

/// The native material boundary, expressed in the backdrop view's coordinates.
struct OverlayGlassHitRegion: Equatable {
    let rect: CGRect
    let cornerRadius: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
              rect.width > 0, rect.height > 0, rect.contains(point) else { return false }
        let radius = min(max(0, cornerRadius.isFinite ? cornerRadius : 0), min(rect.width, rect.height) / 2)
        let dx = max(0, max(rect.minX + radius - point.x, point.x - (rect.maxX - radius)))
        let dy = max(0, max(rect.minY + radius - point.y, point.y - (rect.maxY - radius)))
        return dx * dx + dy * dy <= radius * radius
    }
}

/// A drag keeps its initial owner even when selection or resizing crosses a gap.
struct OverlayGapPointerPolicy {
    private(set) var ignoresMouseEvents = false
    private(set) var dragBelongsToOverlay: Bool?

    mutating func update(insideRegion: Bool, pressedButtons: Int,
                         dragBeganInOverlay: Bool? = nil, hasModalContent: Bool = false) -> Bool {
        if pressedButtons == 0 { dragBelongsToOverlay = nil }
        else if dragBelongsToOverlay == nil, let dragBeganInOverlay {
            dragBelongsToOverlay = dragBeganInOverlay
        }
        if hasModalContent {
            ignoresMouseEvents = false
        } else if let dragBelongsToOverlay {
            ignoresMouseEvents = !dragBelongsToOverlay
        } else if pressedButtons == 0 {
            ignoresMouseEvents = !insideRegion
        }
        // Attaching or resizing during an existing drag never changes its owner.
        return ignoresMouseEvents
    }

    mutating func reset() {
        ignoresMouseEvents = false
        dragBelongsToOverlay = nil
    }
}

/// View hit testing cannot route events to another application. Native pointer
/// observations update the panel before the next click, without polling or replay.
@MainActor
final class OverlayGapMousePassthrough {
    private weak var window: NSWindow?
    private weak var sourceView: NSView?
    private var regions: [OverlayGlassHitRegion] = []
    private var policy = OverlayGapPointerPolicy()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let originalAcceptsMouseMovedEvents: Bool

    init(window: NSWindow) {
        self.window = window
        originalAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    func update(regions: [OverlayGlassHitRegion], in view: NSView) {
        self.regions = regions
        sourceView = view
        installMonitors()
        refresh()
    }

    func removeRegions(in view: NSView) {
        guard sourceView === view else { return }
        sourceView = nil
        regions.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        window?.acceptsMouseMovedEvents = originalAcceptsMouseMovedEvents
        policy.reset()
        window?.ignoresMouseEvents = false
    }

    func refresh() {
        updatePointer(pressedButtons: NSEvent.pressedMouseButtons)
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        window?.acceptsMouseMovedEvents = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event, belongsToOverlay: event.window === self?.window)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event, belongsToOverlay: false)
        }
    }

    private func observe(_ event: NSEvent, belongsToOverlay: Bool) {
        var buttons = NSEvent.pressedMouseButtons
        var beganInOverlay: Bool?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttons |= 1 << event.buttonNumber
            beganInOverlay = belongsToOverlay
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttons &= ~(1 << event.buttonNumber)
        default: break
        }
        updatePointer(pressedButtons: buttons, dragBeganInOverlay: beganInOverlay)
    }

    private func updatePointer(pressedButtons: Int, dragBeganInOverlay: Bool? = nil) {
        guard let window else { return }
        // If the system cannot observe movement over other apps, keep the panel
        // reachable rather than disable input without a way to restore it.
        guard globalMonitor != nil, window.isVisible, let sourceView, sourceView.window === window else {
            policy.reset()
            window.ignoresMouseEvents = false
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = sourceView.convert(windowPoint, from: nil)
        let ignore = policy.update(insideRegion: regions.contains { $0.contains(point) },
            pressedButtons: pressedButtons, dragBeganInOverlay: dragBeganInOverlay,
            hasModalContent: window.attachedSheet != nil)
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }
}
