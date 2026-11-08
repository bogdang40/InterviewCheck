import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Export the actual SwiftUI composition, including screen travel, for review.
@MainActor
final class AbleyWelcomePreviewTests: XCTestCase {
    func testExportNativeWelcomeMovieFrames() async throws {
        try OverlayRenderHarness.skipUnlessEnabled()
        let frames = AbleyWelcomeFrames()
        let directory = try OverlayRenderHarness.outputDirectory().appendingPathComponent("movie-frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size: CGFloat = 760
        let fps = 30.0
        let total = Int((AbleyWelcomeMotion.duration + 0.5) * fps)
        for index in 0..<total {
            let time = Double(index) / fps
            let image = try await frames.image(at: AbleyWelcomeMotion.frameIndex(at: time))
            let root = ZStack {
                OverlayShellView(width: size)
                AbleyWelcomeScene(elapsed: time, image: image, onSkip: {})
            }
            .frame(width: size, height: size)
            .background(OverlayPalette.canvas)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(x: 0, y: 0, width: size, height: size)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let window = MaterialPreviewPanel(contentRect: hosting.frame)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(String(format: "welcome-%04d.png", index)))
            window.close()
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, total)
        print("WELCOME_MOVIE_FRAMES \(directory.path) fps=30 count=\(total)")
    }
}
