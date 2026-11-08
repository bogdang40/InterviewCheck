import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class OverlayAmbientAnimationTests: XCTestCase {
    private final class Visibility: ObservableObject {
        @Published var isVisible = true
        @Published var isEnabled = true
    }

    private struct Fixture: View {
        @ObservedObject var visibility: Visibility
        let parentAppeared: () -> Void
        let phaseChanged: (Bool) -> Void

        var body: some View {
            VStack {
                TextField("Draft", text: .constant("Preserved draft"))
                    .onAppear(perform: parentAppeared)
                OverlayAmbientAnimation(isEnabled: visibility.isEnabled,
                    animation: .linear(duration: 1).repeatForever(autoreverses: true)) { phase in
                    Circle()
                        .frame(width: 10, height: 10)
                        .scaleEffect(phase ? 1.05 : 1)
                        .onAppear { phaseChanged(phase) }
                        .onChange(of: phase) { _, current in phaseChanged(current) }
                }
            }
            .environment(\.overlayContentIsVisible, visibility.isVisible)
        }
    }

    func testVisibilityAndEnabledStateReplaceOnlyTheDecorativeLoop() {
        let visibility = Visibility()
        var phases: [Bool] = []
        var parentAppearances = 0
        let hosting = NSHostingView(rootView: Fixture(visibility: visibility,
            parentAppeared: { parentAppearances += 1 }, phaseChanged: { phases.append($0) }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        // ARC owns this fixture. AppKit's close-time release would overrelease it
        // when XCTest drains the surrounding autorelease pool after the test.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }

        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }

        settle()
        XCTAssertEqual(phases.last, true)
        XCTAssertEqual(parentAppearances, 1)
        visibility.isVisible = false
        settle()
        XCTAssertEqual(phases.last, false)
        visibility.isVisible = true
        settle()
        XCTAssertEqual(phases.last, true)
        visibility.isEnabled = false
        settle()
        XCTAssertEqual(phases.last, false)
        visibility.isEnabled = true
        settle()
        XCTAssertEqual(phases.last, true)
        XCTAssertEqual(parentAppearances, 1, "Stopping decoration must retain the surrounding editor")
    }
}
