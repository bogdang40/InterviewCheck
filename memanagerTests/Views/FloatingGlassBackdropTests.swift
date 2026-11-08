import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class FloatingGlassBackdropTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = try await GlassBorderTestResources.prepared()
    }

    func testThreeNativeMaterialsFollowIslandGeometryAndStayMountedThroughResize() throws {
        let first = FloatingShellGeometry(size: CGSize(width: 1200, height: 900), borderWidth: 12)
        let backdrop = FloatingGlassBackdropView(geometry: first, appearance: recipe(.glass, width: 12))
        let hosts = backdrop.subviews.compactMap { $0 as? OverlayGlassHost }
        XCTAssertEqual(hosts.count, 3)
        XCTAssertTrue(backdrop.isFlipped)
        XCTAssertFalse(backdrop.isOpaque)
        XCTAssertNil(backdrop.hitTest(CGPoint(x: first.content.midX, y: first.content.midY)))

        for size in [CGSize(width: 1200, height: 900), CGSize(width: 424, height: 900)] {
            let geometry = FloatingShellGeometry(size: size, borderWidth: 12)
            backdrop.frame = CGRect(origin: .zero, size: size)
            backdrop.update(geometry: geometry)
            backdrop.layoutSubtreeIfNeeded()
            for (index, rect) in [geometry.navigation, geometry.content, geometry.dock].enumerated() {
                XCTAssertTrue(backdrop.subviews[index] === hosts[index])
                XCTAssertEqual(hosts[index].frame, rect.insetBy(dx: -12, dy: -12))
                let material = try XCTUnwrap(hosts[index].subviews.first as? NSVisualEffectView)
                XCTAssertEqual(material.material, .underWindowBackground)
                XCTAssertEqual(material.state, .active)
                XCTAssertEqual(material.blendingMode, .behindWindow)
                XCTAssertFalse(hosts[index].hostedContent.isDescendant(of: material))
            }
        }
    }

    func testForestTintRemainsTranslucentAndDoesNotDimText() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Native glass requires macOS 26") }
        let forest = NSColor(srgbRed: 32.0 / 255, green: 58.0 / 255, blue: 44.0 / 255, alpha: 1)
        let content = NSTextField(string: "Visible answer")
        let host = OverlayGlassHost(contentView: content, materialTint: forest,
            tintPlacement: .overlay, observesSettings: false)
        let material = try XCTUnwrap(host.subviews.first as? NSGlassEffectView)
        for opacity in [0.5, 0.75, 1, -.infinity, .infinity, .nan] {
            host.updateMaterialOpacity(opacity)
            XCTAssertNil(material.tintColor, "Clear glass must not receive a semantic material tint.")
            let tint = try XCTUnwrap(host.materialOverlay?.fillColor.usingColorSpace(.sRGB))
            XCTAssertEqual(tint.redComponent, forest.redComponent, accuracy: 0.001)
            XCTAssertEqual(tint.greenComponent, forest.greenComponent, accuracy: 0.001)
            XCTAssertEqual(tint.blueComponent, forest.blueComponent, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(tint.alphaComponent, 0.12)
            XCTAssertLessThanOrEqual(tint.alphaComponent, 0.20)
            XCTAssertEqual(host.alphaValue, 1)
            XCTAssertEqual(content.alphaValue, 1)
        }
        host.updateBorder(style: .none, configuration: nil)
        XCTAssertTrue(material.isHidden)
        XCTAssertEqual(host.materialOverlay?.isHidden, true)
        XCTAssertEqual(host.contentInset, 0)
        host.updateBorder(style: .liquid, configuration: .liquidDefault)
        XCTAssertFalse(material.isHidden)
        XCTAssertEqual(host.materialOverlay?.isHidden, false)
        XCTAssertTrue(host.hostedContent === content)
    }

    func testSingleSnapshotSwitchesNativeAndReadingSurfacesWithoutDeferredOverrides() throws {
        let settings = SettingsManager.shared
        let oldStyle = settings.borderShaderStyle
        let oldWidth = settings.overlayWidth
        settings.overlayWidth = 400
        let initial = FloatingShellGeometry(size: CGSize(width: 400, height: 680), borderWidth: 0)
        let backdrop = FloatingGlassBackdropView(geometry: initial, appearance: recipe(.none, width: 0))
        let hosts = backdrop.subviews.compactMap { $0 as? OverlayGlassHost }
        let fallbacks = hosts.map(\.hostedContent)
        let borders = hosts.compactMap { $0.subviews.last as? OverlayGlassBorderView }
        let window = OverlayWindow()
        window.contentView = backdrop
        window.configureContentViewLayer()
        defer {
            backdrop.detachPointerRegions()
            window.contentView = nil
            window.close()
            settings.borderShaderStyle = oldStyle
            settings.overlayWidth = oldWidth
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let selections: [(BorderShaderStyle, CGFloat)] = [(.glass, 12), (.liquid, 48), (.none, 0),
            (.liquid, 6), (.none, 0), (.liquid, 6), (.none, 0), (.liquid, 6), (.glass, 6)]
        for (style, width) in selections {
            let geometry = FloatingShellGeometry(size: window.contentLayoutRect.size, borderWidth: width)
            backdrop.update(geometry: geometry, appearance: recipe(style, width: Double(width)))
            let finalGeometry = FloatingShellGeometry(size: window.contentLayoutRect.size, borderWidth: width)
            let rects = [finalGeometry.navigation, finalGeometry.content, finalGeometry.dock]
            XCTAssertEqual(window.borderOutset, width)
            XCTAssertEqual(window.frame.width - 2 * width, 400)
            for (index, host) in hosts.enumerated() {
                XCTAssertTrue(backdrop.subviews[index] === host)
                XCTAssertTrue(host.hostedContent === fallbacks[index])
                XCTAssertTrue(host.subviews.last === borders[index])
                XCTAssertEqual(host.frame, rects[index].insetBy(dx: -width, dy: -width))
                XCTAssertEqual(host.contentInset, width)
                XCTAssertEqual(host.subviews.first?.isHidden, style == .none)
                XCTAssertFalse(fallbacks[index].isHidden, "Every appearance retains its reading texture.")
                let reading = try XCTUnwrap(fallbacks[index] as? NSHostingView<OverlayReadingSurface>)
                XCTAssertEqual(reading.rootView.style, style)
                XCTAssertFalse(reading.rootView.usesSolidFallback)
                XCTAssertEqual((host.subviews.first as? NSVisualEffectView)?.state, .active)
            }
            let frames = hosts.map(\.frame)
            let materialsHidden = hosts.map { $0.subviews.first?.isHidden }
            let fallbackHidden = fallbacks.map(\.isHidden)
            // A delayed settings observer would overwrite this explicitly
            // applied snapshot and independently resize the window.
            settings.borderShaderStyle = style == .none ? .liquid : .none
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(window.borderOutset, width)
            XCTAssertEqual(hosts.map(\.frame), frames)
            XCTAssertEqual(hosts.map { $0.subviews.first?.isHidden }, materialsHidden)
            XCTAssertEqual(fallbacks.map(\.isHidden), fallbackHidden)
            for host in hosts {
                XCTAssertEqual((host.subviews.last as? OverlayGlassBorderView)?.style, style)
                XCTAssertEqual(host.subviews.first?.isHidden, style == .none)
            }
        }
        backdrop.update(geometry: FloatingShellGeometry(size: window.contentLayoutRect.size, borderWidth: 6),
            appearance: recipe(.glass, width: 6, solid: true))
        for host in hosts {
            XCTAssertEqual(host.subviews.first?.isHidden, true)
            XCTAssertFalse(host.hostedContent.isHidden)
            XCTAssertEqual(host.materialOverlay?.isHidden, true)
            let reading = try XCTUnwrap(host.hostedContent as? NSHostingView<OverlayReadingSurface>)
            XCTAssertTrue(reading.rootView.usesSolidFallback)
        }
    }

    private func recipe(_ style: BorderShaderStyle, width: Double, solid: Bool = false) -> FloatingGlassAppearance {
        var configuration = BorderShaderConfiguration.preset(for: style)
        configuration?.width = width
        return FloatingGlassAppearance(style: style, configuration: configuration,
            opacity: 0.75, usesSolidFallback: solid, colorScheme: .dark)
    }

    func testTransparentRootKeepsGlobalBorderOutsetAndLogicalContentWidth() {
        let settings = SettingsManager.shared
        let originalStyle = settings.borderShaderStyle
        let originalGlass = settings.glassBorderConfiguration
        let originalWidth = settings.overlayWidth
        settings.overlayWidth = 400
        let window = OverlayWindow()
        window.contentView = NSView()
        window.configureContentViewLayer()
        defer {
            window.contentView = nil
            window.close()
            settings.borderShaderStyle = originalStyle
            settings.updateConfiguration(originalGlass, for: .glass)
            settings.overlayWidth = originalWidth
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        for width: Double in [12, 48, 0, 2] {
            var configuration = BorderShaderConfiguration.glassDefault
            configuration.width = max(2, width)
            settings.updateConfiguration(configuration, for: .glass)
            settings.borderShaderStyle = width == 0 ? .none : .glass
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(window.borderOutset, CGFloat(width))
            XCTAssertEqual(window.frame.width - 2 * window.borderOutset, settings.overlayWidth)
            XCTAssertEqual(settings.overlayWidth, 400)
        }
    }
}
