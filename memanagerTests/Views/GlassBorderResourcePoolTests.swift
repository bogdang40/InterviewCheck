import AppKit
import XCTest
@testable import memanager

@MainActor
enum GlassBorderTestResources {
    static func prepared(pool: GlassBorderResourcePool? = nil) async throws -> GlassBorderResources {
        let pool = pool ?? .shared
        return try await withCheckedThrowingContinuation { continuation in
            pool.prepare { continuation.resume(with: $0) }
        }
    }
}

@MainActor
final class GlassBorderResourcePoolTests: XCTestCase {
    func testColdPreparationRunsOffMainAndCoalescesRequests() async throws {
        let entered = expectation(description: "Preparation ran")
        let ready = expectation(description: "All requests completed")
        ready.expectedFulfillmentCount = 20
        var calls = 0
        let pool = GlassBorderResourcePool {
            XCTAssertFalse(Thread.isMainThread)
            calls += 1
            entered.fulfill()
            return try GlassBorderResources()
        }
        var resources: [GlassBorderResources] = []
        for _ in 0..<20 {
            pool.prepare { result in
                XCTAssertTrue(Thread.isMainThread)
                if case .success(let value) = result { resources.append(value) }
                else { XCTFail("Metal preparation failed: \(result)") }
                ready.fulfill()
            }
        }
        await fulfillment(of: [entered, ready], timeout: 30)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(resources.count, 20)
        XCTAssertTrue(resources.allSatisfy { $0 === resources.first })
        var deliveredSynchronously = false
        pool.prepare { _ in deliveredSynchronously = true }
        XCTAssertTrue(deliveredSynchronously, "Warm appearance changes must not wait for another run-loop turn")
    }

    func testDelayedPreparationCannotReviveNoneAndDoesNotRetainHost() async throws {
        let gate = DispatchSemaphore(value: 0)
        let pool = GlassBorderResourcePool {
            guard gate.wait(timeout: .now() + 10) == .success else {
                throw GlassRenderError.encoderUnavailable
            }
            return try GlassBorderResources()
        }
        let border = OverlayGlassBorderView(cornerRadius: 36, inset: 12, style: .glass, resourcePool: pool)
        border.setStyle(.liquid)
        border.setStyle(.none)
        weak var released: OverlayGlassBorderView?
        autoreleasepool {
            let temporary = OverlayGlassBorderView(cornerRadius: 36, inset: 12, resourcePool: pool)
            released = temporary
        }
        XCTAssertNil(released)
        gate.signal()
        _ = try await GlassBorderTestResources.prepared(pool: pool)
        XCTAssertNil(border.metalView)
        XCTAssertTrue(border.isHidden)
        XCTAssertFalse(border.usesSolidBorder)
        border.setStyle(.liquid)
        let metal = try XCTUnwrap(border.metalView)
        for style in [BorderShaderStyle.none, .glass, .liquid, .none] {
            border.setStyle(style)
            XCTAssertTrue(border.metalView === metal)
        }
        XCTAssertTrue(metal.isPaused)
        XCTAssertFalse(metal.isAnimationRunning)
        XCTAssertTrue(metal.isHidden)
        XCTAssertFalse(metal.enableSetNeedsDisplay)
        let count = metal.completedFrameCount
        metal.draw(in: metal)
        XCTAssertEqual(metal.completedFrameCount, count)
    }

    func testPreparationFailureFallsBackAndNoneRemainsEmpty() async {
        let pool = GlassBorderResourcePool { throw GlassRenderError.missingKernel }
        let border = OverlayGlassBorderView(cornerRadius: 36, inset: 12, resourcePool: pool)
        do {
            _ = try await GlassBorderTestResources.prepared(pool: pool)
            XCTFail("Expected preparation failure")
        } catch {
            XCTAssertTrue(border.usesSolidBorder)
            XCTAssertNil(border.metalView)
        }
        border.setStyle(.none)
        XCTAssertFalse(border.usesSolidBorder)
        XCTAssertTrue(border.isHidden)
    }
}
