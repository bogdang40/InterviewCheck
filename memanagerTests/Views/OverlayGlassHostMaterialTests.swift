import AppKit
import XCTest
@testable import memanager

@MainActor
final class OverlayGlassHostMaterialTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = try await GlassBorderTestResources.prepared()
    }

    func testReadingMaterialSurvivesNativeKeyTransitionsWithoutChangingBlurOrEditorState() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEMANAGER_NATIVE_FOCUS_SMOKE"] == "1",
            "Set MEMANAGER_NATIVE_FOCUS_SMOKE=1 for an interactive foreground focus test.")
        let editor = NSTextView()
        editor.string = "Keep this answer readable while editing."
        let host = makeHost(editor)
        let material = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let originalKeyWindow = NSApp.keyWindow
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        let window = makeWindow(content: host)
        let secondWindow = makeWindow(content: NSView())
        window.title = "Abley material focus check"
        secondWindow.title = "Abley focus transfer check"
        window.center()
        secondWindow.setFrameOrigin(NSPoint(x: window.frame.minX + 24, y: window.frame.minY - 24))
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            secondWindow.contentView = nil
            window.close()
            secondWindow.close()
            if originalKeyWindow?.isVisible == true { originalKeyWindow?.makeKey() }
            if let originalFrontmost {
                NSApp.yieldActivation(to: originalFrontmost)
                originalFrontmost.activate(options: [])
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 4))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            for style in [BorderShaderStyle.glass, .none, .liquid] {
                host.applyAppearance(style: style, configuration: .preset(for: style),
                    opacity: 0.75, usesSolidFallback: false)
                host.layoutSubtreeIfNeeded()
                let contentFrame = editor.convert(editor.bounds, to: host)
                let materialMask = material.maskImage
                let tint = host.materialOverlay?.fillColor
                // Hidden windows cannot become key in the hosted runner. This
                // opt-in test briefly orders real windows for native lifecycle.
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(window.isKeyWindow)
                assertReadingMaterial(material, host: host, style: style)
                secondWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(secondWindow.isKeyWindow)
                XCTAssertFalse(window.isKeyWindow)
                assertReadingMaterial(material, host: host, style: style)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(window.isKeyWindow)
                assertReadingMaterial(material, host: host, style: style)
                XCTAssertTrue(host.subviews.last === border)
                XCTAssertTrue(material.maskImage === materialMask)
                XCTAssertEqual(host.materialOverlay?.fillColor, tint)
                XCTAssertEqual(editor.convert(editor.bounds, to: host), contentFrame)
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 4))
                XCTAssertEqual(editor.string, "Keep this answer readable while editing.")
            }
        }
    }

    func testReadingMaterialAccessibilityFallbackAndOpacityPreserveNativeBlurRecipe() throws {
        let editor = NSTextView()
        let host = makeHost(editor)
        let material = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)
        for opacity in [0.5, 0.75, 1, -.infinity, .infinity, .nan] {
            for solid in [false, true, false] {
                host.applyAppearance(style: .liquid, configuration: .liquidDefault,
                    opacity: opacity, usesSolidFallback: solid)
                XCTAssertTrue(host.subviews.first === material)
                XCTAssertEqual(material.state, .active)
                XCTAssertEqual(material.blendingMode, .behindWindow)
                XCTAssertFalse(material.isEmphasized)
                XCTAssertEqual(material.alphaValue, 1)
                XCTAssertEqual(material.isHidden, solid)
                XCTAssertEqual(host.materialOverlay?.isHidden, solid)
                let alpha = try XCTUnwrap(host.materialOverlay?.fillColor.alphaComponent)
                XCTAssertGreaterThanOrEqual(alpha, 0.24)
                XCTAssertLessThanOrEqual(alpha, 0.36)
                XCTAssertEqual(editor.alphaValue, 1)
            }
        }
    }

    private func makeHost(_ content: NSView) -> OverlayGlassHost {
        let forest = NSColor(srgbRed: 32.0 / 255, green: 58.0 / 255, blue: 44.0 / 255, alpha: 1)
        return OverlayGlassHost(contentView: content, materialTint: forest,
            tintPlacement: .overlay, observesSettings: false, materialBehavior: .stableReading)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func assertReadingMaterial(_ material: NSVisualEffectView, host: OverlayGlassHost,
                                       style: BorderShaderStyle, file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertTrue(host.subviews.first === material, file: file, line: line)
        XCTAssertEqual(material.material, .underWindowBackground, file: file, line: line)
        XCTAssertEqual(material.blendingMode, .behindWindow, file: file, line: line)
        XCTAssertEqual(material.state, .active, file: file, line: line)
        XCTAssertFalse(material.isEmphasized, file: file, line: line)
        XCTAssertEqual(material.alphaValue, 1, file: file, line: line)
        XCTAssertEqual(material.isHidden, style == .none, file: file, line: line)
    }
}
