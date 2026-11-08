import Combine
import XCTest
@testable import memanager

@MainActor
final class CanvasDirectorTests: XCTestCase {
    func testRefreshingHighlightCancelsOldExpiryAndIgnoresItsCallback() async {
        let clock = CanvasDecayClock()
        let director = CanvasDirector(scheduleDecay: clock.schedule)
        let first = highlight(ttl: 500)
        director.apply([.highlight(first)])
        await drainMainQueue()
        let refreshed = highlight(ttl: 1_500)
        director.apply([.highlight(refreshed)])
        await drainMainQueue()

        XCTAssertEqual(director.scene.highlights, [refreshed])
        XCTAssertTrue(clock.cancelled.contains(0))
        // Cancellation can race a callback that was already queued.
        clock.entries[0].action()
        XCTAssertEqual(director.scene.highlights, [refreshed])
        clock.entries[1].action()
        XCTAssertTrue(director.scene.highlights.isEmpty)
    }

    func testSeparateHighlightsExpireIndependently() async {
        let clock = CanvasDecayClock()
        let director = CanvasDirector(scheduleDecay: clock.schedule)
        let left = highlight(value: "1")
        let right = highlight(value: "2")
        director.apply([.highlight(left), .highlight(right)])
        await drainMainQueue()

        XCTAssertTrue(clock.cancelled.isEmpty)
        clock.entries[0].action()
        XCTAssertEqual(director.scene.highlights, [right])
    }

    func testClearCancelsOnlyTargetExpiryAndAllowsNewHighlight() async {
        let clock = CanvasDecayClock()
        let director = CanvasDirector(scheduleDecay: clock.schedule)
        let first = highlight()
        let other = highlight(target: "other")
        director.apply([.highlight(first), .highlight(other), .clear(sceneID: "array"), .highlight(first)])
        await drainMainQueue()

        XCTAssertTrue(clock.cancelled.contains(0))
        XCTAssertFalse(clock.cancelled.contains(1))
        XCTAssertEqual(director.scene.highlights, [other, first])
        clock.entries[0].action()
        XCTAssertEqual(director.scene.highlights, [other, first])
    }

    func testResetCancelsExpiryAndBoundsMinimumDuration() async {
        let clock = CanvasDecayClock()
        let director = CanvasDirector(scheduleDecay: clock.schedule)
        director.apply([.highlight(highlight(ttl: -1))])
        await drainMainQueue()
        XCTAssertEqual(clock.entries.first?.milliseconds, 200)

        director.reset()
        await drainMainQueue()
        XCTAssertTrue(clock.cancelled.contains(0))
        clock.entries[0].action()
        XCTAssertEqual(director.scene, .empty)
    }

    func testClearingArrayRemovesPointersByTheirTarget() {
        var scene = CanvasScene.empty
        scene.apply(.pointer(CanvasPointerPayload(id: "left", targetID: "array", op: .set, name: "left", index: 1)))
        scene.apply(.pointer(CanvasPointerPayload(id: "right", targetID: "other", op: .set, name: "right", index: 2)))
        scene.apply(.clear(sceneID: "array"))

        XCTAssertNil(scene.pointers["left"])
        XCTAssertNotNil(scene.pointers["right"])
    }

    private func highlight(target: String = "array", value: String = "1", ttl: Int = 500) -> CanvasHighlightPayload {
        CanvasHighlightPayload(targetID: target, kind: .indices, value: value, ttlMs: ttl)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class CanvasDecayClock {
    struct Entry {
        let milliseconds: Int
        let action: () -> Void
    }

    var entries: [Entry] = []
    var cancelled = Set<Int>()

    func schedule(milliseconds: Int, action: @escaping () -> Void) -> AnyCancellable {
        let index = entries.count
        entries.append(Entry(milliseconds: milliseconds, action: action))
        return AnyCancellable { [weak self] in self?.cancelled.insert(index) }
    }
}
