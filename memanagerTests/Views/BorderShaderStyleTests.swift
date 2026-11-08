import AppKit
import XCTest
@testable import memanager

@MainActor
final class BorderShaderStyleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = try await GlassBorderTestResources.prepared()
    }

    func testRestorationPreservesAllChoicesAndDefaultsToLiquid() {
        XCTAssertEqual(BorderShaderStyle.restored(from: nil), .liquid)
        XCTAssertEqual(BorderShaderStyle.restored(from: "obsolete"), .liquid)
        for style in BorderShaderStyle.allCases {
            XCTAssertEqual(BorderShaderStyle.restored(from: style.rawValue), style)
        }
    }

    func testLiquidUsesWaterOpticsAndNoneHasNoRendererConfiguration() throws {
        let glass = try XCTUnwrap(BorderShaderStyle.glass.optics)
        let liquid = try XCTUnwrap(BorderShaderStyle.liquid.optics)
        XCTAssertEqual(glass.liquid, 0)
        XCTAssertEqual(liquid.liquid, 1)
        XCTAssertEqual(liquid.ior, 1.333, accuracy: 0.001)
        XCTAssertLessThan(liquid.dispersion, glass.dispersion)
        XCTAssertNil(BorderShaderStyle.none.optics)
    }

    func testPersistedSelectionUpdatesExistingHostAndPreservesEditor() async throws {
        let settings = SettingsManager.shared
        let original = settings.borderShaderStyle
        let persisted = AppDefaults.standard.object(forKey: "memanager.borderShaderStyle")
        let appearance = settings.overlayAppearance
        let opacity = settings.overlayOpacity
        settings.borderShaderStyle = .glass
        let editor = NSTextView()
        editor.string = "An unfinished question"
        let host = OverlayGlassHost(contentView: editor, cornerRadius: 36)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer {
            host.onBorderApplied = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            settings.borderShaderStyle = original
            if let persisted { AppDefaults.standard.set(persisted, forKey: "memanager.borderShaderStyle") }
            else { AppDefaults.standard.removeObject(forKey: "memanager.borderShaderStyle") }
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let material = try XCTUnwrap(host.subviews.first)
        let initialMetal = border.metalView
        for style in [BorderShaderStyle.liquid, .none, .glass] {
            let applied = expectation(description: "Native border applied \(style.rawValue)")
            host.onBorderApplied = { appliedStyle, _, _ in
                if appliedStyle == style { applied.fulfill() }
            }
            settings.borderShaderStyle = style
            await fulfillment(of: [applied], timeout: 2)
            host.onBorderApplied = nil
            XCTAssertEqual(border.style, style)
            XCTAssertEqual(AppDefaults.standard.string(forKey: "memanager.borderShaderStyle"), style.rawValue)
            XCTAssertTrue(host.subviews.first === material)
            XCTAssertTrue(host.subviews.last === border)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
            XCTAssertEqual(editor.string, "An unfinished question")
            XCTAssertTrue(host.hostedContent === editor)
            XCTAssertNil(border.hitTest(CGPoint(x: 1, y: 1)))
            if style == .liquid, let initialMetal {
                XCTAssertTrue(border.metalView === initialMetal)
                XCTAssertEqual(initialMetal.optics.liquid, settings.configuration(for: .liquid)?.optics.liquid)
            }
            if style == .none {
                XCTAssertTrue(border.metalView === initialMetal)
                XCTAssertFalse(border.usesSolidBorder)
                XCTAssertTrue(border.isHidden)
                XCTAssertTrue(initialMetal?.isPaused ?? true)
                XCTAssertFalse(initialMetal?.isAnimationRunning ?? false)
                XCTAssertTrue(initialMetal?.superview === border)
            }
        }
        XCTAssertEqual(settings.overlayAppearance, appearance)
        XCTAssertEqual(settings.overlayOpacity, opacity)
    }

    func testNoneCreatesNoMetalViewAndRetiredRendererCannotDraw() throws {
        let border = OverlayGlassBorderView(cornerRadius: 36, inset: 12, style: .none)
        XCTAssertNil(border.metalView)
        XCTAssertFalse(border.usesSolidBorder)
        XCTAssertTrue(border.isHidden)
        XCTAssertTrue(border.subviews.isEmpty)
        let metal = GlassBorderMetalView(cornerRadius: 36, inset: 12, resources: try GlassBorderResources())
        metal.setRenderingEnabled(false)
        let completed = metal.completedFrameCount
        metal.draw(in: metal)
        XCTAssertTrue(metal.isPaused)
        XCTAssertFalse(metal.isAnimationRunning)
        XCTAssertEqual(metal.completedFrameCount, completed)
        XCTAssertFalse(metal.hasFailed)
    }
}
