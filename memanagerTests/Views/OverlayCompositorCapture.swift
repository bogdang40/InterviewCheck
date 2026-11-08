import AppKit
import ScreenCaptureKit
import XCTest
@testable import memanager

/// Opt-in WindowServer evidence. Only the two synthetic preview windows are
/// included in the filter; production windows and the desktop are excluded.
@MainActor
enum OverlayCompositorCapture {
    static func capture(_ name: String, size: CGSize, appearance: OverlayAppearance,
                        contentView: NSView, outputDirectory: URL, validate: () throws -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw failure("Screen capture access is not granted. No permission was requested and no compositor image was saved.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let margin: CGFloat = 32
        let sceneSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        guard sceneSize.width <= screen.visibleFrame.width, sceneSize.height <= screen.visibleFrame.height else {
            throw failure("Preview plus shadow margin does not fit the primary display. Choose a smaller fixture.")
        }
        let sceneFrame = CGRect(x: screen.visibleFrame.midX - sceneSize.width / 2,
                                y: screen.visibleFrame.midY - sceneSize.height / 2,
                                width: sceneSize.width, height: sceneSize.height)
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originalKey = NSApp.keyWindow
        let backdrop = MaterialPreviewPanel(contentRect: sceneFrame)
        backdrop.hasShadow = false
        backdrop.isOpaque = true
        backdrop.contentView = MaterialPreviewBackdrop(frame: CGRect(origin: .zero, size: sceneSize))
        let panel = MaterialPreviewPanel(contentRect: sceneFrame.insetBy(dx: margin, dy: margin))
        panel.title = "Memanager native glass preview"
        panel.hasShadow = true
        panel.appearance = appearance.nativeAppearance
        contentView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = contentView
        defer { panel.close(); backdrop.close() }

        backdrop.orderFrontRegardless()
        panel.orderFrontRegardless()
        contentView.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        try await Task.sleep(for: .seconds(0.7))
        contentView.layoutSubtreeIfNeeded()
        try validate()
        try assertFocusUnchanged(frontmost: originalFrontmost, keyWindow: originalKey)

        let shareable: SCShareableContent = try await waitForResult("enumerating preview windows") { done in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content { done(.success(content)) }
                else { done(.failure(error ?? failure("ScreenCaptureKit returned no shareable content."))) }
            }
        }
        let display = try XCTUnwrap(shareable.displays.first { $0.displayID == CGMainDisplayID() })
        let ids = Set([CGWindowID(panel.windowNumber), CGWindowID(backdrop.windowNumber)])
        let windows = shareable.windows.filter { ids.contains($0.windowID) }
        guard windows.count == 2 else { throw failure("The compositor did not expose both preview windows.") }
        let filter = SCContentFilter(display: display, including: windows)
        if #available(macOS 14.2, *) { filter.includeMenuBar = false }
        let config = SCStreamConfiguration()
        // sourceRect uses display-local points with a top-left origin.
        config.sourceRect = CGRect(x: sceneFrame.minX - screen.frame.minX,
                                   y: screen.frame.maxY - sceneFrame.maxY,
                                   width: sceneSize.width, height: sceneSize.height)
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((sceneSize.width * scale).rounded())
        config.height = Int((sceneSize.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsDisplay = false
        config.shouldBeOpaque = true
        let image: CGImage = try await waitForResult("capturing the native glass preview") { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { done(.success(image)) }
                else { done(.failure(error ?? failure("ScreenCaptureKit returned no image."))) }
            }
        }
        try assertFocusUnchanged(frontmost: originalFrontmost, keyWindow: originalKey)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = outputDirectory.appendingPathComponent("\(name)-compositor.png")
        try png.write(to: url)
        let metadata: [String: Any] = [
            "capture": "ScreenCaptureKit display filter containing only the synthetic backdrop and preview panel",
            "fixture": name, "appearance": appearance.rawValue,
            "widthPixels": image.width, "heightPixels": image.height,
            "shadowMarginPoints": margin, "focusUnchanged": true,
            "productionCaptureProtectionChanged": false
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("\(name)-compositor.json"))
        print("COMPOSITOR_RENDERED \(url.path)")
    }

    private static func assertFocusUnchanged(frontmost: pid_t?, keyWindow: NSWindow?) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
              NSApp.keyWindow === keyWindow else {
            throw failure("Keyboard focus changed during the preview. No compositor evidence was accepted.")
        }
    }

    private static func waitForResult<Value>(_ stage: String,
        start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let result = MaterialPreviewResult<Value>()
        start { result.complete($0) }
        let deadline = Date().addingTimeInterval(8)
        while result.read() == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let completed = result.read() else { throw failure("Timed out while \(stage). No compositor image was saved.") }
        return try completed.get()
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "OverlayCompositorCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Showing the preview never activates the app or accepts mouse/keyboard input.
@MainActor
final class MaterialPreviewPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MaterialPreviewResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func complete(_ result: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = result
    }
    func read() -> Result<Value, Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class MaterialPreviewBackdrop: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let colors = [NSColor(calibratedWhite: 0.94, alpha: 1),
                      NSColor(calibratedRed: 0.50, green: 0.73, blue: 0.77, alpha: 1),
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
