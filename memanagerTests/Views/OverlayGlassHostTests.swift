import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class OverlayGlassHostTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = try await GlassBorderTestResources.prepared()
    }

    private func makeHost(contentView: NSView, cornerRadius: CGFloat) -> OverlayGlassHost {
        let host = OverlayGlassHost(contentView: contentView, cornerRadius: cornerRadius)
        host.updateBorder(style: .glass, configuration: .glassDefault)
        return host
    }

    func testNativeGlassIsBackgroundAndContentRemainsStableAcrossAppearanceChanges() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Native glass requires macOS 26") }
        let content = NSTextField(string: "Draft stays here")
        let host = makeHost(contentView: content, cornerRadius: 26)
        let glass = try XCTUnwrap(host.subviews.first as? NSGlassEffectView)

        XCTAssertNil(glass.contentView)
        XCTAssertTrue(host.contentContainer.superview === host)
        XCTAssertFalse(content.isDescendant(of: glass))
        XCTAssertTrue(content.isDescendant(of: host.contentContainer))
        XCTAssertTrue(host.hostedContent === content)
        XCTAssertEqual(glass.style, .clear)
        XCTAssertEqual(glass.cornerRadius, 26 + OverlayLayout.glassPerimeterInset)
        XCTAssertFalse(host.clipsToBounds)

        host.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .aqua)
        XCTAssertNil(glass.contentView)
        XCTAssertTrue(host.contentContainer.superview === host)
        XCTAssertFalse(content.isDescendant(of: glass))
        XCTAssertTrue(content.isDescendant(of: host.contentContainer))
        XCTAssertEqual(content.stringValue, "Draft stays here")
        XCTAssertEqual(host.subviews.count, 3)

        host.updateMaterialOpacity(1)
        XCTAssertEqual(try XCTUnwrap(glass.tintColor).alphaComponent, 0.2, accuracy: 0.001)
        host.updateMaterialOpacity(0.5)
        XCTAssertEqual(try XCTUnwrap(glass.tintColor).alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(content.alphaValue, 1)
        XCTAssertEqual(host.alphaValue, 1)
        XCTAssertNil(glass.contentView)
        XCTAssertTrue(host.contentContainer.superview === host)
        XCTAssertFalse(content.isDescendant(of: glass))
        XCTAssertTrue(content.isDescendant(of: host.contentContainer))
    }

    func testPerimeterInsetsContentAndNeverInterceptsHits() throws {
        let content = NSTextField(string: "Editable draft")
        let host = makeHost(contentView: content, cornerRadius: 26)
        // A bare text field has a fixed intrinsic height. Give this fixture a
        // required viewport; the production SwiftUI host's flexible viewport
        // and resizing are exercised separately below without these constraints.
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 400),
            host.heightAnchor.constraint(equalToConstant: 300)
        ])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let inner = try XCTUnwrap(content.superview)
        let contentRect = content.convert(content.bounds, to: host)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, CGSize(width: 400, height: 300))
        XCTAssertEqual(host.bounds.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(contentRect, host.bounds.insetBy(dx: OverlayLayout.glassPerimeterInset, dy: OverlayLayout.glassPerimeterInset))
        XCTAssertEqual(host.contentInset, OverlayLayout.glassPerimeterInset)
        XCTAssertEqual(inner.layer?.cornerRadius, 26)
        let insetConstraints = host.contentContainer.constraints.filter {
            ($0.firstItem as? NSView) === inner
        }
        XCTAssertEqual(insetConstraints.count, 4)
        XCTAssertTrue(insetConstraints.allSatisfy { abs($0.constant) == host.contentInset })
        let bezel = try XCTUnwrap(host.subviews.compactMap { $0 as? OverlayGlassBorderView }.first)
        XCTAssertNil(bezel.hitTest(CGPoint(x: 2, y: 2)))
        XCTAssertNil(bezel.hitTest(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(bezel.acceptsFirstResponder)
        XCTAssertTrue(host.hostedContent === content)
    }

    func testGeometryReaderReceivesTheNativePanelViewportWhenResized() {
        var measuredSize: CGSize = .zero
        let content = MousePassthroughHostingView(rootView: GeometryReader { geometry in
            VStack {
                TextField("Question", text: .constant("Draft"))
                Spacer()
            }
            .onAppear { measuredSize = geometry.size }
            .onChange(of: geometry.size) { _, size in measuredSize = size }
        })
        let host = makeHost(contentView: content, cornerRadius: OverlayLayout.panelCornerRadius)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        for size in [CGSize(width: 400, height: 300), CGSize(width: 620, height: 540)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let expected = CGRect(origin: .zero, size: size)
                .insetBy(dx: OverlayLayout.glassPerimeterInset, dy: OverlayLayout.glassPerimeterInset)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, size)
            XCTAssertEqual(host.bounds.size, size)
            XCTAssertEqual(content.convert(content.bounds, to: host), expected)
            XCTAssertEqual(measuredSize, expected.size)
            XCTAssertTrue(host.hostedContent === content)
        }
    }

    func testBorderCompositionPreservesEditorFocusAndNativeOrdering() throws {
        let editor = NSTextView()
        editor.string = "Question draft"
        let host = makeHost(contentView: editor, cornerRadius: OverlayLayout.panelCornerRadius)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 400),
            host.heightAnchor.constraint(equalToConstant: 300)
        ])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let border = try XCTUnwrap(host.subviews.last as? OverlayGlassBorderView)
        XCTAssertFalse(border.isDescendant(of: host.contentContainer))
        XCTAssertFalse(border.isOpaque)
        XCTAssertFalse(border.acceptsFirstResponder)
        XCTAssertNil(border.hitTest(CGPoint(x: 200, y: 150)))
        XCTAssertTrue(host.hitTest(CGPoint(x: 200, y: 150)) === editor)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            host.updateMaterialOpacity(0.75)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
            XCTAssertEqual(editor.string, "Question draft")
            XCTAssertTrue(host.subviews.last === border)
        }
    }

    func testMetalBorderIsTransparentDemandDrivenAndRejectsInput() throws {
        let metal = GlassBorderMetalView(cornerRadius: 36, inset: 12, resources: try GlassBorderResources())
        XCTAssertTrue(metal.isPaused)
        XCTAssertFalse(metal.isAnimationRunning)
        XCTAssertFalse(metal.enableSetNeedsDisplay)
        XCTAssertFalse(metal.isOpaque)
        XCTAssertEqual(metal.layer?.isOpaque, false)
        XCTAssertEqual(metal.clearColor.alpha, 0)
        XCTAssertFalse(metal.acceptsFirstResponder)
        XCTAssertNil(metal.hitTest(CGPoint(x: 10, y: 10)))
        metal.draw(in: metal)
        XCTAssertFalse(metal.hasFailed, "Detached or hidden windows must not acquire a drawable or fail")
    }

}
