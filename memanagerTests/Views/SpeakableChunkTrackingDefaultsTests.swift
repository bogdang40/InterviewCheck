import XCTest
import SwiftUI
import AppKit
@testable import memanager

final class SpeakableChunkTrackingDefaultsTests: XCTestCase {
    @MainActor
    func testRetainedInactiveScriptCannotOverwriteActiveCounterAndRestoresItsCursor() {
        let controller = SessionController.shared
        controller.resetSessionStateForTesting()
        defer { controller.resetSessionStateForTesting() }
        let hosting = NSHostingView(rootView: RetainedChunksFixture(solveActive: true, hiddenText: "Design"))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        XCTAssertEqual(controller.totalChunkCount, 3)
        controller.currentChunkIndex = 2
        settle()
        hosting.rootView = RetainedChunksFixture(solveActive: true, hiddenText: "Design one\n\nDesign two")
        settle()
        XCTAssertEqual(controller.totalChunkCount, 3, "Hidden updates must not replace the visible script count")
        XCTAssertEqual(controller.currentChunkIndex, 2)
        hosting.rootView = RetainedChunksFixture(solveActive: false, hiddenText: "Design one\n\nDesign two")
        settle()
        XCTAssertEqual(controller.totalChunkCount, 2)
        XCTAssertEqual(controller.currentChunkIndex, 0)
        controller.currentChunkIndex = 1
        settle()
        hosting.rootView = RetainedChunksFixture(solveActive: true, hiddenText: "Design one\n\nDesign two")
        settle()
        XCTAssertEqual(controller.totalChunkCount, 3)
        XCTAssertEqual(controller.currentChunkIndex, 2, "Returning to the retained Solve script restores its own cursor")
    }

    func testSpeakableChunksViewDefaultsToTeleprompterTracking() {
        let view = SpeakableChunksView(text: "chunk one\n\nchunk two")

        XCTAssertEqual(view.chunkTrackingMode, .teleprompter)
    }

    func testSpeakableMarkdownViewDefaultsToTeleprompterTracking() {
        let view = SpeakableMarkdownView(text: "some markdown text")

        XCTAssertEqual(view.chunkTrackingMode, .teleprompter)
    }

    func testChunkTrackingModeCanBeExplicitlyDisabled() {
        let chunksView = SpeakableChunksView(
            text: "chunk one",
            chunkTrackingMode: .none
        )
        let markdownView = SpeakableMarkdownView(
            text: "markdown",
            chunkTrackingMode: .none
        )

        XCTAssertEqual(chunksView.chunkTrackingMode, .none)
        XCTAssertEqual(markdownView.chunkTrackingMode, .none)
    }
}

private struct RetainedChunksFixture: View {
    let solveActive: Bool
    let hiddenText: String

    var body: some View {
        ZStack {
            SpeakableChunksView(text: "Solve one\n\nSolve two\n\nSolve three")
                .disabled(!solveActive)
                .opacity(solveActive ? 1 : 0)
            SpeakableChunksView(text: hiddenText)
                .disabled(solveActive)
                .opacity(solveActive ? 0 : 1)
        }
    }
}
