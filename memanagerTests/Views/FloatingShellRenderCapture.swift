import AppKit
import ScreenCaptureKit
import XCTest
@testable import memanager

@MainActor
enum FloatingShellRenderCapture {
    static func raster(_ name: String, size: CGSize, content: NSView,
                       directory: URL, validate: () throws -> Void) async throws {
        let panel = MaterialPreviewPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content
        defer { panel.contentView = nil; panel.close() }
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        content.layoutSubtreeIfNeeded()
        try validate()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = directory.appendingPathComponent(name + "-raster.png")
        try png.write(to: path)
        try metadata(["capture": "NSView cacheDisplay raster", "fixture": name,
            "nativeGlassVerified": false, "productionCaptureProtectionChanged": false,
            "limitation": "Layout only. Native desktop transmission and Metal presentation require the compositor image."],
            name: name + "-raster", directory: directory)
        print("FLOATING_RASTER_LAYOUT_ONLY \(path.path)")
    }

    static func unavailable(_ name: String, directory: URL, reason: String) throws {
        try metadata(["capture": "unavailable", "fixture": name, "nativeGlassVerified": false,
            "reason": reason], name: name + "-compositor-status", directory: directory)
        print("FLOATING_COMPOSITOR_UNAVAILABLE \(name): \(reason)")
    }

    static func previewIfRequested(_ name: String, size: CGSize, content: NSView,
                                   image: NSImage?, directory: URL, validate: () throws -> Void) async throws {
        guard let raw = ProcessInfo.processInfo.environment["MEMANAGER_FLOATING_PREVIEW_SECONDS"],
              let requested = Double(raw), requested.isFinite, requested > 0 else { return }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let margin: CGFloat = 32
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2 - margin,
            y: screen.visibleFrame.midY - size.height / 2 - margin,
            width: size.width + 2 * margin, height: size.height + 2 * margin)
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let previousKeyWindow = NSApp.keyWindow
        // One owned scene lets window-only UI screenshots include the artwork.
        // This proves native pane composition over a synthetic sibling view;
        // the separate two-window capture remains the desktop transmission test.
        let scene = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let backdrop = FloatingShellPreviewBackdrop(image: image, size: frame.size)
        backdrop.setAccessibilityHidden(true)
        scene.addSubview(backdrop)
        content.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: size)
        scene.addSubview(content)
        let panel = FloatingShellInspectionPanel(contentRect: frame)
        panel.isOpaque = false
        panel.title = "Abley floating preview \(name)"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = scene
        defer {
            panel.makeFirstResponder(nil)
            content.removeFromSuperview()
            panel.contentView = nil
            panel.close()
            if previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKey() }
            if let previousFrontmost {
                NSApp.yieldActivation(to: previousFrontmost)
                previousFrontmost.activate(options: [])
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        scene.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        content.layoutSubtreeIfNeeded()
        try validate()
        try metadata(["fixture": name, "capture": "manual window-only UI inspection",
            "backdrop": "synthetic artwork sibling inside the same owned preview window",
            "desktopTransmissionVerified": false, "productionCaptureProtectionChanged": false,
            "limitation": "Native glass composition over an in-window synthetic backdrop. This does not prove desktop transmission."],
            name: name + "-manual-preview", directory: directory)
        print("FLOATING_PREVIEW_READY \(name) pid=\(ProcessInfo.processInfo.processIdentifier) seconds=\(min(60, requested))")
        try await Task.sleep(for: .seconds(min(60, requested)))
    }

    /// Includes only these two synthetic windows. The demo image is never
    /// installed into an app resource or placed behind production content.
    static func wallpaper(_ name: String, size: CGSize, content: NSView, image: NSImage,
                          directory: URL, validate: () throws -> Void) async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let margin: CGFloat = 32
        let sceneSize = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard sceneSize.width <= screen.visibleFrame.width, sceneSize.height <= screen.visibleFrame.height else {
            throw failure("Wallpaper preview and margin do not fit the primary display.")
        }
        let sceneFrame = CGRect(x: screen.visibleFrame.midX - sceneSize.width / 2,
            y: screen.visibleFrame.midY - sceneSize.height / 2, width: sceneSize.width, height: sceneSize.height)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp.keyWindow
        let backdrop = MaterialPreviewPanel(contentRect: sceneFrame)
        backdrop.hasShadow = false
        backdrop.isOpaque = true
        backdrop.contentView = FloatingShellPreviewBackdrop(image: image, size: sceneSize)
        let panel = MaterialPreviewPanel(contentRect: sceneFrame.insetBy(dx: margin, dy: margin))
        panel.appearance = NSAppearance(named: .darkAqua)
        content.frame = CGRect(origin: .zero, size: size)
        panel.contentView = content
        defer { panel.contentView = nil; panel.close(); backdrop.close() }
        backdrop.orderFrontRegardless()
        panel.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        content.layoutSubtreeIfNeeded()
        try validate()

        let shareable: SCShareableContent = try await result("enumerating wallpaper preview") { done in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content { done(.success(content)) }
                else { done(.failure(error ?? failure("No shareable preview windows."))) }
            }
        }
        let display = try XCTUnwrap(shareable.displays.first { $0.displayID == CGMainDisplayID() })
        let ids = Set([CGWindowID(panel.windowNumber), CGWindowID(backdrop.windowNumber)])
        let windows = shareable.windows.filter { ids.contains($0.windowID) }
        guard windows.count == 2 else { throw failure("Both synthetic preview windows must be shareable.") }
        let filter = SCContentFilter(display: display, including: windows)
        if #available(macOS 14.2, *) { filter.includeMenuBar = false }
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: sceneFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - sceneFrame.maxY, width: sceneSize.width, height: sceneSize.height)
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((sceneSize.width * scale).rounded())
        config.height = Int((sceneSize.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsDisplay = false
        config.shouldBeOpaque = true
        let capture: CGImage = try await result("capturing wallpaper preview") { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { done(.success(image)) }
                else { done(.failure(error ?? failure("No screenshot was returned."))) }
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, NSApp.keyWindow === keyWindow else {
            throw failure("Preview changed keyboard ownership; capture was not accepted.")
        }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]))
        let path = directory.appendingPathComponent(name + "-compositor.png")
        try png.write(to: path)
        try metadata(["capture": "ScreenCaptureKit with only two synthetic preview windows", "fixture": name,
            "backdrop": "demo wallpaper from explicit test environment path, never shipped", "focusUnchanged": true,
            "productionCaptureProtectionChanged": false, "nativeGlassCaptured": true, "visualInspectionRequired": true,
            "widthPixels": capture.width, "heightPixels": capture.height, "shadowMarginPoints": margin],
            name: name + "-compositor", directory: directory)
        print("FLOATING_WALLPAPER_COMPOSITOR \(path.path)")
    }

    private static func metadata(_ object: [String: Any], name: String, directory: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }

    private static func result<Value>(_ stage: String,
        start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let outcome = FloatingShellCaptureResult<Value>()
        start { outcome.complete($0) }
        let deadline = Date().addingTimeInterval(8)
        while outcome.read() == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let completed = outcome.read() else { throw failure("Timed out while \(stage).") }
        return try completed.get()
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "FloatingShellRenderCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Explicit manual QA only. Compositor captures still use passive panels and
/// production OverlayWindow capture protection is never changed.
@MainActor
private final class FloatingShellInspectionPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .none
        titlebarAppearsTransparent = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FloatingShellCaptureResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func complete(_ value: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        if self.value == nil { self.value = value }
    }
    func read() -> Result<Value, Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class FloatingShellPreviewBackdrop: NSView {
    private let image: NSImage?
    init(image: NSImage?, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            drawContrastGrid()
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    private func drawContrastGrid() {
        let colors = [NSColor(calibratedWhite: 0.94, alpha: 1),
                      NSColor(calibratedRed: 0.5, green: 0.73, blue: 0.77, alpha: 1),
                      NSColor(calibratedWhite: 0.19, alpha: 1)]
        for (index, color) in colors.enumerated() {
            color.setFill()
            CGRect(x: bounds.width * CGFloat(index) / 3, y: 0,
                   width: bounds.width / 3 + 1, height: bounds.height).fill()
        }
        NSColor(calibratedWhite: 0.5, alpha: 0.35).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for x in stride(from: CGFloat(0), through: bounds.width, by: 24) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.line(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 24) {
            grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: bounds.width, y: y))
        }
        grid.stroke()
    }
}
