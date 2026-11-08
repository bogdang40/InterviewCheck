import AppKit
import SwiftUI
import XCTest
@testable import InterviewCheck

/// Opt-in screenshots of SwiftUI views, light and dark, written as PNG.
/// Enable with INTERVIEWCHECK_RENDER_SMOKE=1; files go to INTERVIEWCHECK_RENDER_DIR.
@MainActor
enum RenderHarness {
    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INTERVIEWCHECK_RENDER_SMOKE"] == "1", "render smoke is opt in")
    }

    static func render<Content: View>(
        _ name: String,
        size: CGSize,
        settle: TimeInterval = 0.4,
        @ViewBuilder content: () -> Content
    ) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INTERVIEWCHECK_RENDER_DIR"] ?? NSTemporaryDirectory(),
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            let hosting = NSHostingView(rootView: content()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, suffix == "dark" ? .dark : .light))
            hosting.appearance = appearance
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
