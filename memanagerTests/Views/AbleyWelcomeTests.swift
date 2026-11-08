import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class AbleyWelcomeTests: XCTestCase {
    func testRunLandsAtTheDockAcrossWindowSizes() {
        for size in [CGSize(width: 400, height: 760), CGSize(width: 1000, height: 760), CGSize(width: 720, height: 480)] {
            let start = AbleyWelcomeMotion(elapsed: 0, size: size)
            XCTAssertGreaterThan(start.characterSize, 300)
            let finish = AbleyWelcomeMotion(elapsed: AbleyWelcomeMotion.duration, size: size)
            XCTAssertEqual(finish.center, AbleyWelcomeMotion.dockCenter(in: size))
            XCTAssertEqual(finish.center, FloatingShellGeometry(size: size, borderWidth: 0).brandCenter,
                           "The mascot must dock in the current navigation brand slot.")
            XCTAssertLessThan(AbleyWelcomeMotion(elapsed: 2.8, size: size).center.x, start.center.x)
            XCTAssertEqual(finish.characterSize, AbleyWelcomeMotion.dockSize, accuracy: 0.001)
            XCTAssertEqual(finish.iconOpacity, 1)
            XCTAssertEqual(finish.backdropOpacity, 0)
            var previousSize = start.characterSize
            for time in stride(from: 0.0, through: 4.3, by: 0.1) {
                let pose = AbleyWelcomeMotion(elapsed: time, size: size)
                XCTAssertLessThanOrEqual(pose.characterSize, previousSize + 0.001)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(pose.center))
                previousSize = pose.characterSize
            }
        }
    }

    func testWelcomeEndpointFollowsTheActualGlassBorderAndNavigationLayout() {
        for width: CGFloat in [400, 760, 1000] {
            for border: CGFloat in [0, 12, 48] {
                let size = CGSize(width: width + 2 * border, height: 760 + 2 * border)
                let finish = AbleyWelcomeMotion(elapsed: AbleyWelcomeMotion.duration, size: size, borderWidth: border)
                XCTAssertEqual(finish.center, FloatingShellGeometry(size: size, borderWidth: border).brandCenter)
            }
        }
    }

    func testReducedMotionKeepsTheCharacterStill() {
        let size = CGSize(width: 400, height: 760)
        let start = AbleyWelcomeMotion(elapsed: 0, size: size, reduceMotion: true)
        let finish = AbleyWelcomeMotion(elapsed: 1.2, size: size, reduceMotion: true)
        XCTAssertEqual(start.center, finish.center)
        XCTAssertEqual(start.characterSize, finish.characterSize)
        XCTAssertEqual(finish.greetingOpacity, 1)
        XCTAssertEqual(finish.iconOpacity, 0)
    }

    func testFrameIndexStaysInsideThePack() {
        XCTAssertEqual(AbleyWelcomeMotion.frameIndex(at: -1), 0)
        XCTAssertEqual(AbleyWelcomeMotion.frameIndex(at: .nan), 0)
        XCTAssertEqual(AbleyWelcomeMotion.frameIndex(at: 1), 30)
        XCTAssertEqual(AbleyWelcomeMotion.frameIndex(at: 4.3), 119)
        XCTAssertEqual(AbleyWelcomeMotion.frameIndex(at: .greatestFiniteMagnitude), 119)
    }

    func testEveryBundledFrameDecodesWithAlpha() async throws {
        let frames = AbleyWelcomeFrames()
        for index in 0..<AbleyWelcomeMotion.frameCount {
            let image = try await frames.image(at: index)
            XCTAssertGreaterThanOrEqual(image.width, 512)
            XCTAssertEqual(image.width, image.height)
            XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last].contains(image.alphaInfo))
        }
    }

    func testCancelledPlaybackCannotFinishLater() async throws {
        let playback = AbleyWelcomePlayback()
        var completions = 0
        let task = Task { await playback.play(reduceMotion: true) { completions += 1 } }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertEqual(completions, 0)
    }

    func testReducedMotionCompletesWithoutAdvancingFrames() async {
        let playback = AbleyWelcomePlayback()
        var completions = 0
        await playback.play(reduceMotion: true) { completions += 1 }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(playback.elapsed, 0)
        XCTAssertTrue(playback.usesStillGreeting)
    }

    func testMissingFramesStillDismissTheGreeting() async {
        let playback = AbleyWelcomePlayback()
        let frames = AbleyWelcomeFrames(bundle: Bundle(for: Self.self))
        var completions = 0
        await playback.play(reduceMotion: false, frames: frames) { completions += 1 }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(playback.usesStillGreeting)
        XCTAssertNil(playback.image)
    }

    func testRenderWelcomeStoryboard() async throws {
        try OverlayRenderHarness.skipUnlessEnabled()
        let frames = AbleyWelcomeFrames()
        for width: CGFloat in [400, 1000] {
            for (name, time) in [("hello", 0.8), ("turn", 1.9), ("run", 2.8), ("dock", 4.3)] {
                let image = try await frames.image(at: AbleyWelcomeMotion.frameIndex(at: time))
                try await OverlayRenderHarness.render("abley-welcome-\(name)-\(Int(width))",
                    size: CGSize(width: width, height: 760), settle: 0.1) {
                    ZStack {
                        OverlayShellView(width: width)
                        AbleyWelcomeScene(elapsed: time, image: image, onSkip: {})
                    }
                }
            }
        }
    }
}
