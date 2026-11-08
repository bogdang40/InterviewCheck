import AppKit
import Combine
import XCTest
@testable import memanager

@MainActor
final class AppearanceUpdateSchedulingTests: XCTestCase {
    func testMaterialSelectionAppliesAfterTheSettingWriteWithoutReadingStaleState() async throws {
        let settings = SettingsManager.shared
        let originalStyle = settings.borderShaderStyle
        settings.borderShaderStyle = .none
        let host = OverlayGlassHost(contentView: NSView())
        defer { settings.borderShaderStyle = originalStyle }
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let material = try XCTUnwrap(host.subviews.first)
        var styleSeenDuringGeometry: BorderShaderStyle?
        host.onBorderWidthChange = { _ in styleSeenDuringGeometry = settings.borderShaderStyle }

        for style in [BorderShaderStyle.glass, .liquid, .none, .glass, .none] {
            let priorStyle = border.style
            styleSeenDuringGeometry = nil
            settings.borderShaderStyle = style
            XCTAssertEqual(border.style, priorStyle, "Native layout must not run inside @Published willSet")
            await drainMainQueue()
            XCTAssertEqual(border.style, style)
            XCTAssertEqual(host.contentInset, CGFloat(settings.configuration(for: style)?.width ?? 0))
            XCTAssertEqual(material.isHidden, style == .none)
            if let styleSeenDuringGeometry { XCTAssertEqual(styleSeenDuringGeometry, style) }
        }
    }

    func testUnchangedWidthDoesNotRequestWindowGeometryWork() {
        let host = OverlayGlassHost(contentView: NSView())
        host.updateBorder(style: .glass, configuration: .glassDefault)
        var widths: [CGFloat] = []
        host.onBorderWidthChange = { widths.append($0) }

        host.updateBorder(style: .glass, configuration: .glassDefault)
        host.updateBorder(style: .liquid, configuration: .liquidDefault)
        var configuration = BorderShaderConfiguration.liquidDefault
        configuration.roughness = 0.02
        host.updateBorder(style: .liquid, configuration: configuration)
        XCTAssertTrue(widths.isEmpty)

        configuration.width = 24
        host.updateBorder(style: .liquid, configuration: configuration)
        host.updateBorder(style: .liquid, configuration: configuration)
        host.updateBorder(style: .none, configuration: nil)
        host.updateBorder(style: .none, configuration: nil)
        XCTAssertEqual(widths, [24, 0])
    }

    func testWindowResizeObservesTheNewContentInset() {
        let host = OverlayGlassHost(contentView: NSView())
        host.updateBorder(style: .none, configuration: nil)
        var appliedWidths: [CGFloat] = []
        host.onBorderWidthChange = { width in
            XCTAssertEqual(host.contentInset, width,
                           "A synchronous window layout must use the new inset")
            appliedWidths.append(width)
        }
        for width: Double in [12, 48, 2, 0] {
            var configuration = BorderShaderConfiguration.glassDefault
            configuration.width = width
            host.updateBorder(style: width == 0 ? .none : .glass,
                              configuration: width == 0 ? nil : configuration)
        }
        XCTAssertEqual(appliedWidths, [12, 48, 2, 0])
    }

    func testRapidSelectionsApplyOnlyTheFinalStyleAndGeometry() async throws {
        let settings = SettingsManager.shared
        let originalStyle = settings.borderShaderStyle
        settings.borderShaderStyle = .none
        let host = OverlayGlassHost(contentView: NSView())
        defer { settings.borderShaderStyle = originalStyle }
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        var widths: [CGFloat] = []
        host.onBorderWidthChange = { widths.append($0) }

        for style in [BorderShaderStyle.glass, .liquid, .none, .glass, .liquid] {
            settings.borderShaderStyle = style
        }
        XCTAssertEqual(border.style, .none)
        XCTAssertTrue(widths.isEmpty)
        await drainMainQueue()
        XCTAssertEqual(border.style, .liquid)
        XCTAssertEqual(widths, [CGFloat(settings.liquidBorderConfiguration.width)])
    }

    func testBorderOutsetChangesDoNotRepublishUnchangedContentWidth() throws {
        let settings = SettingsManager.shared
        let originalWidth = settings.overlayWidth
        settings.overlayWidth = 400
        let host = OverlayGlassHost(contentView: NSView())
        host.updateBorder(style: .none, configuration: nil)
        let window = OverlayWindow()
        window.contentView = host
        window.configureContentViewLayer()
        defer {
            window.contentView = nil
            window.close()
            settings.overlayWidth = originalWidth
        }
        let contentWidth = settings.overlayWidth
        var publishedWidths: [CGFloat] = []
        let subscription = settings.$overlayWidth.dropFirst().sink { publishedWidths.append($0) }
        defer { subscription.cancel() }

        for width: Double in [12, 48, 2, 0] {
            var configuration = BorderShaderConfiguration.glassDefault
            configuration.width = width
            host.updateBorder(style: width == 0 ? .none : .glass,
                              configuration: width == 0 ? nil : configuration)
        }
        XCTAssertTrue(publishedWidths.isEmpty)
        XCTAssertEqual(settings.overlayWidth, contentWidth)

        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        var proposed = window.frame
        proposed.size.width += 50
        window.setFrame(window.constrainFrameRect(proposed, to: screen), display: false)
        XCTAssertEqual(publishedWidths, [contentWidth + 50])
    }

    func testOpacityUpdateAppliesTheCommittedPublishedValue() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Native glass requires macOS 26") }
        let settings = SettingsManager.shared
        let originalOpacity = settings.overlayOpacity
        let host = OverlayGlassHost(contentView: NSView())
        let glass = try XCTUnwrap(host.subviews.first as? NSGlassEffectView)
        defer { settings.overlayOpacity = originalOpacity }

        settings.overlayOpacity = 0.5
        await drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(glass.tintColor).alphaComponent, 0, accuracy: 0.001)
        settings.overlayOpacity = 1
        await drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(glass.tintColor).alphaComponent, 0.2, accuracy: 0.001)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Native appearance transaction applied")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
