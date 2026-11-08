import AppKit
import SwiftUI

final class RegionSelectionWindow: NSWindow {
    private var selectionView: RegionSelectionView?
    private var onComplete: ((NSRect) -> Void)?
    private var onCancel: (() -> Void)?

    init(screen: NSScreen, onComplete: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.ignoresMouseEvents = false

        selectionView = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selectionView?.onSelectionComplete = { [weak self] rect in
            self?.onComplete?(rect)
        }
        selectionView?.onCancel = { [weak self] in
            self?.onCancel?()
        }

        self.contentView = selectionView
        self.makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private class RegionSelectionView: NSView {
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)

        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(current.x - start.x)
        let height = abs(current.y - start.y)

        currentRect = NSRect(x: x, y: y, width: width, height: height)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = currentRect, rect.width > 10, rect.height > 10 {
            onSelectionComplete?(rect)
        }
        startPoint = nil
        currentRect = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw selection rectangle
        guard let rect = currentRect else { return }

        NSColor.white.withAlphaComponent(0.3).setFill()
        rect.fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }
}
