import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class RetainedSettingsContentTests: XCTestCase {
    private final class Visibility: ObservableObject {
        @Published var isVisible = false
    }

    private final class Creation {
        var count = 0
        weak var button: NSButton?
    }

    private struct NativeControl: NSViewRepresentable {
        let creation: Creation
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: "Retained control", target: nil, action: nil)
            creation.count += 1
            creation.button = button
            return button
        }

        func updateNSView(_ view: NSButton, context: Context) {
            view.isEnabled = isEnabled
        }
    }

    private struct Fixture: View {
        @ObservedObject var visibility: Visibility
        let creation: Creation

        var body: some View {
            VStack(spacing: 0) {
                RetainedSettingsContent(isVisible: visibility.isVisible) {
                    NativeControl(creation: creation).frame(height: 120)
                }
                Text("Following content").frame(height: 20)
            }
            .frame(width: 400)
        }
    }

    func testCollapsedControlsRetainNativeIdentityAndRestoreTheirLayout() async throws {
        let visibility = Visibility()
        let creation = Creation()
        let host = NSHostingView(rootView: Fixture(visibility: visibility, creation: creation))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        try await settle(host)
        XCTAssertEqual(host.fittingSize.height, 20, accuracy: 0.5,
                       "Hidden controls must not move the following page content")
        let original = try XCTUnwrap(creation.button)
        XCTAssertFalse(original.isEnabled)

        for visible in [true, false, true] {
            visibility.isVisible = visible
            try await settle(host)
            XCTAssertTrue(creation.button === original)
            XCTAssertEqual(creation.count, 1, "Warm reveals must not reconstruct the native control")
            XCTAssertEqual(original.isEnabled, visible)
            XCTAssertEqual(host.fittingSize.height, visible ? 140 : 20, accuracy: 0.5)
        }
    }

    func testNoneMatchesTheOriginalHeaderOnlyHeightAtCompactAndRegularWidths() async throws {
        for width: CGFloat in [400, 560] {
            let actual = BorderShaderSettingsSection(selection: .constant(.none),
                configuration: .constant(.liquidDefault), onReset: {})
            // None previously contained this header alone, without control spacing.
            let baseline = SettingsSection("Border shader", footer: BorderShaderStyle.none.description) {
                Picker("Border shader", selection: Binding.constant(BorderShaderStyle.none)) {
                    ForEach(BorderShaderStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            let actualHost = NSHostingView(rootView: AnyView(actual.frame(width: width)
                .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: width))))
            let baselineHost = NSHostingView(rootView: AnyView(baseline.frame(width: width)
                .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: width))))
            actualHost.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            baselineHost.frame = actualHost.frame
            try await settle(actualHost)
            try await settle(baselineHost)
            XCTAssertGreaterThan(baselineHost.fittingSize.height, 0)
            XCTAssertEqual(actualHost.fittingSize.height, baselineHost.fittingSize.height, accuracy: 0.5)
        }
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
    }
}
