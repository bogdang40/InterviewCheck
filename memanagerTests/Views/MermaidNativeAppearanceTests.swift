import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import memanager

/// Exercises the production HTML bridge in a visible native host. Async waits
/// yield MainActor so WebKit callbacks and SwiftUI updates can finish normally.
@MainActor
final class MermaidNativeAppearanceTests: XCTestCase {
    private let size = CGSize(width: 760, height: 460)
    private let diagram = """
        flowchart LR
            Client[Client] --> API[API]
            API --> Queue[Queue]
        """

    func testCompletedDiagramRendersAndChangesAppearanceInSameWebView() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEMANAGER_MERMAID_NATIVE"] == "1",
                          "Visible WebKit appearance verification is opt in")
        let directory = try OverlayRenderHarness.outputDirectory()
        let host = NSHostingView(rootView: content(.light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Memanager diagram verification"
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        defer { window.close() }

        var firstWebView: WKWebView?
        var backgrounds: [String] = []
        var nodeFills: [String] = []
        var previousSVG: String?
        for appearance in [OverlayAppearance.light, .dark] {
            host.rootView = content(appearance)
            host.appearance = appearance.nativeAppearance
            window.appearance = appearance.nativeAppearance
            host.layoutSubtreeIfNeeded()
            let webView = try await waitForWebView(in: host)
            XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent,
                           "Native diagram tests must not use the app's website data store")
            if let firstWebView { XCTAssertTrue(webView === firstWebView) }
            else { firstWebView = webView }

            let expectedBackground = appearance == .dark ? "rgb(32, 39, 43)" : "rgb(246, 246, 242)"
            let state = try await waitForDiagram(webView, background: expectedBackground, previousSVG: previousSVG)
            previousSVG = try XCTUnwrap(state["svgID"] as? String)
            backgrounds.append(try XCTUnwrap(state["background"] as? String))
            nodeFills.append(try XCTUnwrap(state["nodeFill"] as? String))
            let labels = try XCTUnwrap(state["labels"] as? String)
            for label in ["Client", "API", "Queue"] { XCTAssertTrue(labels.contains(label)) }
            XCTAssertGreaterThan(state["width"] as? Double ?? 0, 100)
            XCTAssertGreaterThan(state["height"] as? Double ?? 0, 20)

            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            let image = try await webView.takeSnapshot(configuration: configuration)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("mermaid-native-\(appearance.rawValue).png"))
            let evidence = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try evidence.write(to: directory.appendingPathComponent("mermaid-native-\(appearance.rawValue).json"))
        }
        XCTAssertNotEqual(backgrounds.first, backgrounds.last)
        XCTAssertNotEqual(nodeFills.first, nodeFills.last, "Diagram nodes must change theme as well as the page background")
    }

    private func content(_ appearance: OverlayAppearance) -> some View {
        MermaidDiagramView(diagram: diagram, height: size.height)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme!)
    }

    private func waitForWebView(in view: NSView) async throws -> WKWebView {
        for _ in 0..<100 {
            if let webView = descendant(in: view) { return webView }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "MermaidNativeAppearance", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The production WebKit view did not mount."])
    }

    private func descendant(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { self.descendant(in: $0) }.first
    }

    private func waitForDiagram(_ webView: WKWebView, background: String, previousSVG: String?) async throws -> [String: Any] {
        let script = """
            (() => {
                const svg = document.querySelector('#active-layer svg');
                const rect = svg?.getBoundingClientRect();
                const node = svg?.querySelector('.node rect');
                return {background: getComputedStyle(document.body).backgroundColor,
                        labels: svg ? [...svg.querySelectorAll('.node .label')].map(n => n.textContent).join(' ') : '',
                        width: rect?.width || 0,
                        height: rect?.height || 0, ready: document.fonts.status === 'loaded',
                        svgID: svg?.id || '', nodeFill: node ? getComputedStyle(node).fill : ''};
            })()
            """
        var lastState: [String: Any] = [:]
        for _ in 0..<300 {
            if let state = try? await webView.evaluateJavaScript(script) as? [String: Any] {
                lastState = state
                if state["background"] as? String == background,
                   state["ready"] as? Bool == true,
                   state["svgID"] as? String != previousSVG,
                   !(state["nodeFill"] as? String ?? "").isEmpty,
                   (state["labels"] as? String)?.contains("Queue") == true,
                   (state["width"] as? Double ?? 0) > 100 { return state }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "MermaidNativeAppearance", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Diagram did not complete with the expected appearance: \(lastState)"])
    }
}
