import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class FloatingShellRenderTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    func testRenderFloatingAssistWide1120() async throws {
        try await render("floating-assist-wide-1120", size: CGSize(width: 1120, height: 780))
    }

    func testRenderFloatingAssistCompact400() async throws {
        try await render("floating-assist-compact-400", size: CGSize(width: 400, height: 680))
    }

    func testRenderFloatingAssistCompactEmpty400() async throws {
        try await render("floating-assist-compact-empty-400", size: CGSize(width: 400, height: 680), hasAnswer: false)
    }

    func testRenderFloatingAssistNone1120() async throws {
        try await render("floating-assist-none-1120", size: CGSize(width: 1120, height: 780), style: .none)
    }

    func testRapidStyleSelectionsCommitMatchingGeometryAndSurfaces() async throws {
        let fixture = try await FloatingShellRenderFixture.install(style: .none)
        defer { fixture.restore() }
        _ = try await GlassBorderTestResources.prepared()
        let size = CGSize(width: 1120, height: 780)
        let hosting = NSHostingView(rootView: FloatingShellRenderContent(size: size))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let panel = MaterialPreviewPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.contentView = hosting
        defer { panel.contentView = nil; panel.close() }
        hosting.layoutSubtreeIfNeeded()
        for finalStyle in [BorderShaderStyle.liquid, .none, .glass, .liquid, .none, .liquid] {
            // Exercise the production observed SwiftUI path, including bursts
            // that reverse direction before the next layout pass.
            SettingsManager.shared.borderShaderStyle = .none
            SettingsManager.shared.borderShaderStyle = .liquid
            SettingsManager.shared.borderShaderStyle = finalStyle
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            try validate(hosting, size: size, hasAnswer: true, style: finalStyle)
        }
    }

    private func render(_ name: String, size: CGSize, hasAnswer: Bool = true, style: BorderShaderStyle = .liquid) async throws {
        let fixture = try await FloatingShellRenderFixture.install(hasAnswer: hasAnswer, style: style)
        defer { fixture.restore() }
        _ = try await GlassBorderTestResources.prepared()
        let hosting = NSHostingView(rootView: FloatingShellRenderContent(size: size))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let output = try OverlayRenderHarness.outputDirectory()
        let validate = { try self.validate(hosting, size: size, hasAnswer: hasAnswer, style: style) }
        try await FloatingShellRenderCapture.raster(name, size: size, content: hosting,
                                                    directory: output, validate: validate)
        let wallpaper = ProcessInfo.processInfo.environment["MEMANAGER_FLOATING_WALLPAPER"].flatMap(NSImage.init(contentsOfFile:))
        try await FloatingShellRenderCapture.previewIfRequested(name, size: size, content: hosting,
                                                               image: wallpaper, directory: output, validate: validate)
        guard CGPreflightScreenCaptureAccess() else {
            try FloatingShellRenderCapture.unavailable(name, directory: output,
                reason: "Screen capture permission was unavailable. The raster does not verify native glass.")
            return
        }
        do {
            try await OverlayCompositorCapture.capture(name + "-contrast-grid", size: size, appearance: .dark,
                contentView: hosting, outputDirectory: output, validate: validate)
            if let path = ProcessInfo.processInfo.environment["MEMANAGER_FLOATING_WALLPAPER"] {
                let image = try XCTUnwrap(NSImage(contentsOfFile: path), "The requested demo wallpaper must load.")
                try await FloatingShellRenderCapture.wallpaper(name + "-wallpaper", size: size,
                    content: hosting, image: image, directory: output, validate: validate)
            }
        } catch {
            try FloatingShellRenderCapture.unavailable(name, directory: output,
                reason: "Compositor capture failed: \(error.localizedDescription). The raster remains layout evidence only.")
        }
    }

    private func validate(_ view: NSView, size: CGSize, hasAnswer: Bool, style: BorderShaderStyle) throws {
        XCTAssertEqual(view.bounds.size, size)
        let backdrop = try XCTUnwrap(descendants(view).compactMap { $0 as? FloatingGlassBackdropView }.first)
        let hosts = backdrop.subviews.compactMap { $0 as? OverlayGlassHost }
        XCTAssertEqual(hosts.count, 3, "The native shell must retain three separate material regions.")
        let borderWidth = style == .none ? 0 : FloatingShellRenderFixture.borderWidth
        let geometry = FloatingShellGeometry(size: size, borderWidth: borderWidth)
        for (host, rect) in zip(hosts, [geometry.navigation, geometry.content, geometry.dock]) {
            XCTAssertEqual(host.frame, rect.insetBy(dx: -borderWidth, dy: -borderWidth))
            XCTAssertEqual((host.subviews.first as? NSVisualEffectView)?.state, .active)
            XCTAssertEqual(host.subviews.first?.isHidden, style == .none)
            XCTAssertFalse(host.hostedContent.isHidden)
            let reading = try XCTUnwrap(host.hostedContent as? NSHostingView<OverlayReadingSurface>)
            XCTAssertEqual(reading.rootView.style, style)
        }
        XCTAssertEqual(SessionController.shared.selectedQuickAssistTurn?.question,
                       hasAnswer ? FloatingShellRenderFixture.question : nil)
        XCTAssertEqual(SessionController.shared.selectedQuickAssistResponseText,
                       hasAnswer ? FloatingShellRenderFixture.answer : nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
