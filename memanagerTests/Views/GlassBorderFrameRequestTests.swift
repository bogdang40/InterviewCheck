import XCTest
@testable import memanager

final class GlassBorderFrameRequestTests: XCTestCase {
    func testDrawableWaitAdvancesTheSnapshotAtItsEffectiveSpeed() {
        let frame = request(time: 4, sampledAt: 100, speed: 1.5)
        XCTAssertEqual(frame.animationTime(at: 100.1), 4.15, accuracy: 0.00001)
        XCTAssertEqual(frame.animationTime(at: 100.5), 4.75, accuracy: 0.00001)
    }

    func testStaticFramesAndBackwardOrInvalidTimestampsPreservePhase() {
        let staticFrame = request(time: 4, sampledAt: 100, speed: 0)
        XCTAssertEqual(staticFrame.animationTime(at: 200), 4)
        let animated = request(time: 4, sampledAt: 100, speed: 1)
        for timestamp in [99, Double.nan, .infinity] {
            XCTAssertEqual(animated.animationTime(at: timestamp), 4)
        }
    }

    func testLongSystemUptimePreservesSubframePrecision() {
        let uptime = 10_000_000.0
        let frame = request(time: 4, sampledAt: uptime, speed: 1)
        XCTAssertEqual(frame.animationTime(at: uptime + 1.0 / 60), 4 + 1.0 / 60, accuracy: 0.00001)
    }

    func testRegularFramePredictsDisplayPhaseWhileUrgentFrameUsesAcquisitionTime() {
        var frame = request(time: 4, sampledAt: 100, speed: 1.5)
        frame.prediction = GlassBorderFramePrediction(timestamp: 100.03, frameInterval: 1.0 / 30)
        let acquired = 100.001
        let target = frame.prediction?.time(at: acquired)
        XCTAssertEqual(frame.animationTime(at: target ?? acquired), 4.045, accuracy: 0.00001)
        XCTAssertNil(frame.prediction?.time(at: 100.05))
        frame.prediction = nil
        XCTAssertEqual(frame.animationTime(at: frame.prediction?.time(at: acquired) ?? acquired),
                       4.0015, accuracy: 0.00001)
    }

    private func request(time: Float, sampledAt: TimeInterval, speed: Double) -> GlassBorderFrameRequest {
        GlassBorderFrameRequest(generation: 0, configurationRevision: 1,
            size: CGSize(width: 32, height: 32), drawableSize: CGSize(width: 64, height: 64),
            radius: 12, inset: 4, optics: GlassBorderOptics(), time: time,
            sampledAt: sampledAt, effectiveSpeed: speed, measure: false)
    }
}
