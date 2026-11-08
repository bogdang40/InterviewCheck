import Metal
import QuartzCore
import XCTest
@testable import memanager

@MainActor
final class GlassBorderFrameRendererTests: XCTestCase {
    /// No drawable or GPU frame is created. Counting the acquisition boundary
    /// distinguishes cancellation from an attempted empty-layer acquisition.
    private final class EmptyMetalLayer: CAMetalLayer {
        private let countLock = NSLock()
        private var count = 0

        var acquisitionCount: Int {
            countLock.lock()
            defer { countLock.unlock() }
            return count
        }

        override func nextDrawable() -> CAMetalDrawable? {
            countLock.lock()
            count += 1
            countLock.unlock()
            XCTAssertFalse(Thread.isMainThread)
            return nil
        }
    }

    func testInvalidatedRequestSkipsDrawableAcquisitionAndCompletesOnMain() async throws {
        let resources = try await GlassBorderTestResources.prepared()
        let renderer = GlassBorderFrameRenderer(resources: resources)
        let layer = EmptyMetalLayer()
        let stale = request(generation: renderer.validity.current())
        renderer.validity.invalidate()
        let completed = expectation(description: "Cancelled request completed")
        completed.assertForOverFulfill = true

        renderer.render(stale, layer: layer, presented: { _ in
            XCTFail("A cancelled request must not present a frame")
        }) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            guard case .cancelled = outcome else {
                XCTFail("Expected cancellation, received \(outcome)")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(layer.acquisitionCount, 0)
        withExtendedLifetime(renderer) {}
    }

    func testLatestGenerationRecoversAfterCancellationAndMissingDrawableCompletesOnce() async throws {
        let resources = try await GlassBorderTestResources.prepared()
        let renderer = GlassBorderFrameRenderer(resources: resources)
        let layer = EmptyMetalLayer()
        let stale = request(generation: renderer.validity.current())
        renderer.validity.invalidate()
        let completed = expectation(description: "Cancelled and current requests completed")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        var cancellations = 0, unavailable = 0
        let completion: (GlassBorderFrameOutcome) -> Void = { outcome in
            XCTAssertTrue(Thread.isMainThread)
            switch outcome {
            case .cancelled: cancellations += 1
            case .drawableUnavailable: unavailable += 1
            default: XCTFail("Expected cancellation or unavailable drawable, received \(outcome)")
            }
            completed.fulfill()
        }

        renderer.render(stale, layer: layer, presented: nil, completed: completion)
        renderer.render(request(generation: renderer.validity.current()), layer: layer,
                        presented: nil, completed: completion)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(layer.acquisitionCount, 1, "Only the latest request may acquire a surface")
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(unavailable, 1, "A current missing drawable must remain distinguishable for bounded retry")
        withExtendedLifetime(renderer) {}
    }

    func testErrorInvalidatedWhileMainDeliveryIsQueuedCancelsAndReleasesFrameSlot() async {
        let validity = GlassBorderFrameValidity()
        let completed = expectation(description: "Stale error delivered as cancellation")
        completed.assertForOverFulfill = true
        var schedule = GlassBorderRenderSchedule()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        let delivery = GlassBorderFrameDelivery(validity: validity, generation: validity.current()) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            if case .cancelled = outcome {} else { XCTFail("A stale error must not fail the current renderer") }
            _ = schedule.finishFrame(isVisible: true)
            XCTAssertTrue(schedule.beginFrame(isVisible: true), "Cancellation must release the admitted frame slot")
            completed.fulfill()
        }
        delivery.finish(.failed("Superseded GPU command failed"))
        validity.invalidate()
        await fulfillment(of: [completed], timeout: 2)
    }

    func testSuccessfulUninstrumentedCompletionRemainsSuccessWithoutTimings() async {
        let validity = GlassBorderFrameValidity()
        let completed = expectation(description: "Uninstrumented frame completed")
        GlassBorderFrameDelivery(validity: validity, generation: validity.current()) { outcome in
            if case .rendered(let timing) = outcome { XCTAssertNil(timing) }
            else { XCTFail("Successful drawing must not depend on optional timing collection") }
            completed.fulfill()
        }.finish(.rendered(nil))
        await fulfillment(of: [completed], timeout: 2)
    }

    private func request(generation: UInt64) -> GlassBorderFrameRequest {
        GlassBorderFrameRequest(generation: generation, configurationRevision: 1,
            size: CGSize(width: 32, height: 32), drawableSize: CGSize(width: 64, height: 64),
            radius: 12, inset: 4, optics: GlassBorderOptics(), time: 0,
            sampledAt: 0, effectiveSpeed: 0, measure: false)
    }
}
