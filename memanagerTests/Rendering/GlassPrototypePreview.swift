import AppKit
import XCTest
@testable import memanager

/// The actual production host and an owned moving backdrop share one window.
/// The window cannot become key. No screen pixels are requested by this harness.
@MainActor
enum GlassPrototypePreview {
    static func present(contentSize: CGSize, margin: CGFloat,
                        appearance: OverlayAppearance, content: NSView,
                        backdrop: GlassPrototypeScene = .grid) async throws -> [String: Any]? {
        let requested = ProcessInfo.processInfo.environment["MEMANAGER_GLASS_PREVIEW_SECONDS"]
            .flatMap(TimeInterval.init) ?? 0
        guard requested > 0 else { return nil }
        _ = try await GlassBorderTestResources.prepared()
        let duration = min(60, max(1, requested))
        let host = OverlayGlassHost(contentView: content, cornerRadius: OverlayLayout.panelCornerRadius)
        let panelSize = OverlayWindowGeometry.windowFrame(
            around: CGRect(origin: .zero, size: contentSize), borderWidth: host.contentInset).size
        let sceneSize = CGSize(width: panelSize.width + margin * 2, height: panelSize.height + margin * 2)
        let screen = try XCTUnwrap(NSScreen.main)
        try XCTSkipUnless(sceneSize.width <= screen.visibleFrame.width && sceneSize.height <= screen.visibleFrame.height,
            "The expanded native border and backdrop margin must fit the display for complete visual evidence.")
        let sceneFrame = CGRect(x: screen.visibleFrame.midX - sceneSize.width / 2,
            y: screen.visibleFrame.midY - sceneSize.height / 2, width: sceneSize.width, height: sceneSize.height)
        let images = try stride(from: 0.0, to: 48.0, by: 4.0).map { phase in
            NSImage(cgImage: try backdrop.pixels(width: Int(sceneSize.width), height: Int(sceneSize.height),
                phase: phase).image(), size: sceneSize)
        }
        let backdropView = NSImageView(frame: CGRect(origin: .zero, size: sceneSize))
        backdropView.imageScaling = .scaleAxesIndependently
        backdropView.image = images[0]
        backdropView.setAccessibilityElement(false)
        let scene = NSView(frame: CGRect(origin: .zero, size: sceneSize))
        scene.addSubview(backdropView)

        host.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: panelSize)
        host.setAccessibilityHidden(true)
        scene.addSubview(host)
        // The visual fixture is one image; production controls keep their AX tree.
        scene.setAccessibilityElement(true)
        scene.setAccessibilityRole(.image)
        scene.setAccessibilityLabel("Memanager glass preview")
        scene.setAccessibilityChildren([])
        let panel = MaterialPreviewPanel(contentRect: sceneFrame)
        // The owned backdrop covers this entire preview window. The production
        // overlay remains transparent; only this complete scene is opaque.
        panel.isOpaque = true
        panel.title = "Memanager native glass and optical edge preview"
        panel.appearance = appearance.nativeAppearance
        panel.contentView = scene
        panel.hasShadow = false
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originalKey = NSApp.keyWindow
        panel.orderFrontRegardless()
        defer { panel.close() }
        scene.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.size, contentSize,
            "The native border must surround the requested content viewport.")
        // Exercise the production first-show invalidation; do not manually draw
        // or invalidate Metal here, which would hide a paused-view lifecycle bug.
        try await Task.sleep(nanoseconds: 100_000_000)
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let metal = try XCTUnwrap(border.metalView, "The native preview needs its production Metal border")
        let initialFrameCount = metal.completedFrameCount
        let initialFailure = metal.hasFailed
        print("GLASS_PREVIEW_METAL \(appearance.rawValue) completedFrames=\(initialFrameCount) failed=\(initialFailure) hidden=\(metal.isHiddenOrHasHiddenAncestor) windowVisible=\(panel.isVisible) viewSize=\(metal.bounds.size) drawableSize=\(metal.drawableSize)")
        XCTAssertGreaterThan(initialFrameCount, 0,
            "The visible production MTKView must complete a shader frame after first show")
        XCTAssertFalse(initialFailure, "The preview must display the shader, not its failure fallback")
        print("GLASS_PREVIEW_READY \(appearance.rawValue) \(Int(duration)) seconds, production OverlayGlassHost, one window, owned \(backdrop.rawValue) backdrop")
        let started = Date()
        var previousIndex = -1
        while Date().timeIntervalSince(started) < duration {
            let index = Int(Date().timeIntervalSince(started) / 0.45) % images.count
            if index != previousIndex {
                backdropView.image = images[index]
                previousIndex = index
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, originalFrontmost,
            "The synthetic preview must not activate memanager.")
        XCTAssertTrue(NSApp.keyWindow === originalKey, "The synthetic preview must not become key.")
        print("GLASS_PREVIEW_METAL_FINISHED \(appearance.rawValue) completedFrames=\(metal.completedFrameCount) failed=\(metal.hasFailed)")
        return [
            "completedFramesAfter100ms": initialFrameCount,
            "completedFramesAtEnd": metal.completedFrameCount,
            "failedAfter100ms": initialFailure,
            "failedAtEnd": metal.hasFailed,
            "windowVisible": panel.isVisible,
            "metalHidden": metal.isHiddenOrHasHiddenAncestor,
            "contentWidth": content.bounds.width,
            "contentHeight": content.bounds.height,
            "borderWidth": host.contentInset,
            "outerWidth": host.bounds.width,
            "outerHeight": host.bounds.height,
            "drawableWidth": metal.drawableSize.width,
            "drawableHeight": metal.drawableSize.height
        ]
    }
}
