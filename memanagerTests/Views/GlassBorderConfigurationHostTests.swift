import AppKit
import XCTest
@testable import memanager

@MainActor
final class GlassBorderConfigurationHostTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = try await GlassBorderTestResources.prepared()
    }

    func testWidthsAndNoneUpdateGeometryWithoutReplacingContentOrActiveRenderer() throws {
        let settings = SettingsManager.shared
        let originalWidth = settings.overlayWidth
        settings.overlayWidth = 400
        let editor = NSTextView()
        editor.string = "Keep this draft and selection"
        let host = OverlayGlassHost(contentView: editor, cornerRadius: 36)
        host.updateBorder(style: .glass, configuration: .glassDefault)
        let window = OverlayWindow()
        window.contentView = host
        window.configureContentViewLayer()
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            settings.overlayWidth = originalWidth
        }
        host.layoutSubtreeIfNeeded()
        let contentFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        XCTAssertEqual(contentFrame.minY, screen.visibleFrame.minY)
        XCTAssertEqual(contentFrame.maxY, screen.visibleFrame.maxY)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let selection = NSRange(location: 5, length: 4)
        editor.setSelectedRange(selection)
        let material = try XCTUnwrap(host.subviews.first)
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let metal = border.metalView
        let parent = editor.superview
        for width: Double in [2, 12, 48] {
            var configuration = BorderShaderConfiguration.glassDefault
            configuration.width = width
            configuration.animationEnabled = false
            configuration.motionSpeed = 1.5
            host.updateBorder(style: .glass, configuration: configuration)
            host.layoutSubtreeIfNeeded()
            let expectedInset = CGFloat(width)
            XCTAssertEqual(host.contentInset, expectedInset)
            XCTAssertEqual(editor.convert(editor.bounds, to: host), host.bounds.insetBy(dx: expectedInset, dy: expectedInset))
            XCTAssertEqual(window.convertToScreen(editor.convert(editor.bounds, to: nil)), contentFrame)
            XCTAssertEqual(window.frame, contentFrame.insetBy(dx: -expectedInset, dy: -expectedInset))
            XCTAssertEqual(settings.overlayWidth, contentFrame.width)
            XCTAssertEqual(parent?.layer?.cornerRadius, 36)
            XCTAssertEqual(border.cornerRadius, 36 + expectedInset)
            XCTAssertFalse(material.isHidden)
            XCTAssertTrue(editor.superview === parent)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            if let metal {
                XCTAssertTrue(border.metalView === metal)
                XCTAssertEqual(metal.inset, CGFloat(width))
                XCTAssertFalse(metal.animationEnabled)
                XCTAssertEqual(metal.motionSpeed, 1.5)
            }
        }
        host.updateBorder(style: .none, configuration: nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.contentInset, 0)
        XCTAssertEqual(editor.convert(editor.bounds, to: host), host.bounds)
        XCTAssertEqual(window.convertToScreen(editor.convert(editor.bounds, to: nil)), contentFrame)
        XCTAssertEqual(window.frame, contentFrame)
        XCTAssertTrue(material.isHidden, "None must remove the native material rim as well as the custom shader")
        XCTAssertTrue(border.isHidden)
        XCTAssertTrue(border.metalView === metal)
        XCTAssertTrue(metal?.isPaused ?? true)
        XCTAssertFalse(metal?.isAnimationRunning ?? false)
        XCTAssertFalse(border.usesSolidBorder)
        XCTAssertTrue(editor.superview === parent)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, "Keep this draft and selection")
        XCTAssertEqual(host.bounds.size, contentFrame.size)
    }

    func testLiquidRecipeAndGeometryApplyToTheSameMetalView() throws {
        let border = OverlayGlassBorderView(cornerRadius: 36, inset: 12, style: .glass)
        let metal = try XCTUnwrap(border.metalView)
        var water = BorderShaderConfiguration.liquidDefault
        water.width = 24
        water.lightStrength = 0.3
        water.motionSpeed = 0.5
        border.configure(style: .liquid, configuration: water, cornerRadius: 30, inset: 24)
        XCTAssertTrue(border.metalView === metal)
        XCTAssertEqual(metal.radius, 30)
        XCTAssertEqual(metal.inset, 24)
        XCTAssertEqual(metal.optics.liquid, 1)
        XCTAssertEqual(metal.optics.lightMotion, 0.3, accuracy: 0.001)
        XCTAssertEqual(metal.motionSpeed, 0.5)
    }

    func testResizeInstallsInsetsBeforeReentrantLayoutAndRevealsOnlyAtFinalSize() throws {
        let content = NSView()
        let host = OverlayGlassHost(contentView: content, cornerRadius: 26)
        host.updateBorder(style: .glass, configuration: .glassDefault)
        host.updateBorder(style: .none, configuration: nil)
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        let material = try XCTUnwrap(host.subviews.first)
        let metal = try XCTUnwrap(border.metalView)
        let contentSize = CGSize(width: 400, height: 300)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        for width: Double in [12, 24, 0, 12] {
            let priorStyle = border.style
            let priorRevision = metal.configurationRevision
            var resizeCount = 0
            host.onBorderWidthChange = { inset in
                resizeCount += 1
                XCTAssertEqual(host.contentInset, inset)
                XCTAssertEqual(border.style, priorStyle)
                XCTAssertEqual(metal.configurationRevision, priorRevision)
                if priorStyle == .none || width == 0 {
                    XCTAssertTrue(material.isHidden)
                    XCTAssertTrue(border.isHidden)
                }
                window.setContentSize(CGSize(width: contentSize.width + 2 * inset,
                                             height: contentSize.height + 2 * inset))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(content.bounds.size, contentSize)
                XCTAssertEqual(border.style, priorStyle,
                               "Reentrant layout must not apply the new renderer recipe")
                XCTAssertEqual(metal.configurationRevision, priorRevision)
            }
            var configuration = BorderShaderConfiguration.glassDefault
            configuration.width = width
            host.updateBorder(style: width == 0 ? .none : .glass,
                              configuration: width == 0 ? nil : configuration)
            XCTAssertEqual(resizeCount, 1)
            XCTAssertEqual(content.bounds.size, contentSize)
            XCTAssertEqual(border.bounds.size, host.bounds.size)
            XCTAssertEqual(material.isHidden, width == 0)
            XCTAssertEqual(border.isHidden, width == 0)
            XCTAssertTrue(border.metalView === metal)
            XCTAssertEqual(metal.configurationRevision, priorRevision + (width == 0 ? 0 : 1))
        }
    }

    func testRepeatedWindowResizesAndBorderChangesPersistOnlyContentWidth() throws {
        let settings = SettingsManager.shared
        let originalWidth = settings.overlayWidth
        let originalAnchor = settings.overlayAnchorEdge
        settings.overlayWidth = 400
        let content = NSView()
        let host = OverlayGlassHost(contentView: content, cornerRadius: 36)
        let window = OverlayWindow()
        window.contentView = host
        window.configureContentViewLayer()
        defer {
            window.contentView = nil
            window.close()
            settings.overlayWidth = originalWidth
            settings.overlayAnchorEdge = originalAnchor
        }
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        for edge in [OverlayWindow.AnchorEdge.left, .right] {
            window.anchor(to: edge)
            for requestedWidth: CGFloat in [400, 550, 425, 400] {
                var proposed = window.frame
                proposed.size.width = requestedWidth + 2 * window.borderOutset
                window.setFrame(window.constrainFrameRect(proposed, to: screen), display: false)
                let expected = OverlayWindowGeometry.contentFrame(
                    CGRect(x: 0, y: 0, width: requestedWidth, height: 500),
                    in: screen.visibleFrame, edge: edge)
                XCTAssertEqual(settings.overlayWidth, expected.width)
                for borderWidth: Double in [2, 12, 48, 12, 2, 0] {
                    var configuration = BorderShaderConfiguration.glassDefault
                    configuration.width = borderWidth
                    host.updateBorder(style: borderWidth == 0 ? .none : .glass,
                        configuration: borderWidth == 0 ? nil : configuration)
                    window.anchor(to: edge)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(settings.overlayWidth, expected.width)
                    XCTAssertEqual(window.convertToScreen(content.convert(content.bounds, to: nil)), expected)
                    XCTAssertEqual(window.frame.width, expected.width + 2 * CGFloat(borderWidth))
                }
            }
        }
    }

    func testOversizedWidthAndCornerRadiusStayInsideSmallViewport() {
        let host = OverlayGlassHost(contentView: NSView(), cornerRadius: 200)
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 60)
        var configuration = BorderShaderConfiguration.glassDefault
        configuration.width = 48
        host.updateBorder(style: .glass, configuration: configuration)
        XCTAssertEqual(host.contentInset, 30)
        XCTAssertEqual((host.subviews.last as? OverlayGlassBorderView)?.cornerRadius, 30)
        XCTAssertEqual((host.subviews.last as? OverlayGlassBorderView)?.inset, 30)
    }

    func testAnimationClockPreservesPhaseAcrossPauseAndSpeedChanges() {
        var clock = GlassBorderAnimationClock()
        XCTAssertEqual(clock.advance(to: 100, isRunning: false, speed: 1), 0)
        XCTAssertEqual(clock.advance(to: 101, isRunning: true, speed: 1), 1)
        XCTAssertEqual(clock.advance(to: 120, isRunning: false, speed: 1), 1)
        XCTAssertEqual(clock.advance(to: 121, isRunning: true, speed: 2), 3)
        XCTAssertEqual(clock.advance(to: 120, isRunning: true, speed: 2), 3)
        XCTAssertEqual(clock.advance(to: .infinity, isRunning: true, speed: 2), 3)
    }
}
