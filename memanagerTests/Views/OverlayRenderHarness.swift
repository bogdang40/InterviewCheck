import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Opt-in native raster captures. Each fixture is rendered in both appearances.
@MainActor
enum OverlayRenderHarness {
    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEMANAGER_RENDER_SMOKE"] == "1", "render smoke is opt in")
    }

    static func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["MEMANAGER_RENDER_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: base, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Size describes the content viewport; full shell captures include its outward border.
    static func render<Content: View>(
        _ name: String,
        size: CGSize = CGSize(width: 800, height: 900),
        settle: TimeInterval = 0.4,
        validate: (NSView) throws -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) async throws {
        for appearance in [OverlayAppearance.light, .dark] {
            try await capture("\(name)-\(appearance.rawValue)", size: size, settle: settle,
                              appearance: appearance, validate: validate, content: content)
        }
    }

    private static func capture<Content: View>(
        _ name: String, size: CGSize, settle: TimeInterval, appearance: OverlayAppearance,
        validate: (NSView) throws -> Void,
        @ViewBuilder content: () -> Content
    ) async throws {
        let isFullShell = name.hasPrefix("shell-full")
        let configuredWidth = SettingsManager.shared.configuration(for: SettingsManager.shared.borderShaderStyle)?.width ?? 0
        let outset = isFullShell ? CGFloat(configuredWidth) : 0
        let capturedSize = OverlayWindowGeometry.windowFrame(
            around: CGRect(origin: .zero, size: size), borderWidth: outset).size
        let root = content()
            .frame(width: size.width, height: size.height)
            .background(isFullShell ? OverlayPalette.canvas.opacity(0.82) : OverlayPalette.canvas)
            .environment(\.colorScheme, appearance.colorScheme!)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance.nativeAppearance
        hosting.frame = CGRect(origin: .zero, size: size)
        let capturedView: NSView = isFullShell
            ? OverlayGlassHost(contentView: hosting, cornerRadius: OverlayLayout.panelCornerRadius) : hosting
        capturedView.frame = CGRect(origin: .zero, size: capturedSize)
        if ProcessInfo.processInfo.environment["MEMANAGER_RENDER_COMPOSITOR"] == name {
            try await OverlayCompositorCapture.capture(name, size: capturedSize, appearance: appearance,
                contentView: capturedView, outputDirectory: outputDirectory(), validate: { try validate(hosting) })
            XCTAssertEqual(hosting.bounds.size, size, "The border must surround the requested content viewport.")
            return
        }
        let window = MaterialPreviewPanel(contentRect: capturedView.frame)
        window.appearance = appearance.nativeAppearance
        window.contentView = capturedView
        defer { window.close() }
        capturedView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.bounds.size, size, "The border must surround the requested content viewport.")
        // Optional native WindowServer preview for material inspection. The
        // regular bitmap path cannot capture the compositor's glass backdrop.
        let previewNames = ProcessInfo.processInfo.environment["MEMANAGER_RENDER_PREVIEW"]?
            .split(separator: ",").map(String.init) ?? []
        if previewNames.contains(name) {
            window.title = "Memanager material preview"
            window.center()
            window.orderFrontRegardless()
            print("PREVIEW_READY \(name)")
            let requestedDuration = ProcessInfo.processInfo.environment["MEMANAGER_RENDER_PREVIEW_SECONDS"]
                .flatMap(TimeInterval.init) ?? 60
            try await Task.sleep(for: .seconds(min(60, max(10, requestedDuration))))
        }
        // Suspend the main actor so SwiftUI tasks and queued state delivery can
        // finish before capture. A nested run loop cannot guarantee that.
        try await Task.sleep(for: .seconds(settle))
        capturedView.layoutSubtreeIfNeeded()
        try validate(hosting)
        let rep = try XCTUnwrap(capturedView.bitmapImageRepForCachingDisplay(in: capturedView.bounds))
        capturedView.cacheDisplay(in: capturedView.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = try outputDirectory().appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("RENDERED \(url.path)")
    }

    static func assertHorizontalSelectionAtTrailingEdge(in view: NSView,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = try XCTUnwrap(horizontalScrollView(in: view),
                                   "The compact fixture must overflow horizontally.", file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX - 1,
                                    "The initially selected last segment must be visible before capture.",
                                    file: file, line: line)
    }

    private static func horizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView,
           document.bounds.width > scroll.documentVisibleRect.width { return scroll }
        return view.subviews.lazy.compactMap { horizontalScrollView(in: $0) }.first
    }
}
