import XCTest
@testable import memanager

final class GlassBorderPresentationTimelineTests: XCTestCase {
    func testUrgentUpdateCannotOvertakeACommittedFutureFrame() {
        let layer = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        let prediction = GlassBorderFramePrediction(timestamp: 100.02, frameInterval: 1.0 / 30)
        let regular = timeline.target(for: layer, prediction: prediction, now: 100)
        timeline.recordCommit(regular, for: layer)

        XCTAssertEqual(timeline.target(for: layer, prediction: nil, now: 100.001), regular.nextUp,
                       "An urgent frame must not compete with its predecessor at an identical target")
        XCTAssertEqual(timeline.target(for: layer, prediction: prediction, now: 100.001), regular.nextUp,
                       "A repeated display prediction also requires a distinct target")
        XCTAssertEqual(timeline.target(for: layer, prediction: nil, now: 100.04), 100.04)
    }

    func testRepeatedUrgentUpdatesDoNotAccumulateAnIntervalPerEdit() {
        let layer = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        let initialTarget = 10_000_000.02
        var previous = initialTarget
        timeline.recordCommit(previous, for: layer)
        for _ in 0..<100 {
            let target = timeline.target(for: layer, prediction: nil, now: 10_000_000.001)
            XCTAssertEqual(target, previous.nextUp)
            XCTAssertGreaterThan(target, previous)
            timeline.recordCommit(target, for: layer)
            previous = target
        }
        XCTAssertEqual(previous - initialTarget, initialTarget.ulp * 100)
        XCTAssertLessThan(previous - initialTarget, 0.000001,
                          "One hundred competing edits add less than a microsecond even after months of uptime")
    }

    func testUncommittedPredictionCannotDelayTheNextUrgentRequest() {
        let layer = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        _ = timeline.target(for: layer,
            prediction: GlassBorderFramePrediction(timestamp: 100.02, frameInterval: 1.0 / 30), now: 100)
        XCTAssertEqual(timeline.target(for: layer, prediction: nil, now: 100.001), 100.001)
    }

    func testSameLayerGenerationChangesRetainOutstandingTargets() {
        let layer = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        let validity = GlassBorderFrameValidity()
        timeline.recordCommit(100.02, for: layer)
        validity.invalidate()
        XCTAssertEqual(timeline.target(for: layer, prediction: nil, now: 100.001), 100.02.nextUp,
                       "Generation invalidation cannot cancel an already committed presentation")
    }

    func testReplacementLayerDoesNotInheritTheOldLayerTarget() {
        let original = NSObject(), replacement = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        timeline.recordCommit(100.02, for: original)
        XCTAssertEqual(timeline.target(for: replacement, prediction: nil, now: 100.001), 100.001)
        timeline.recordCommit(100.001, for: replacement)
        XCTAssertEqual(timeline.target(for: replacement, prediction: nil, now: 100.002), 100.002)
    }

    func testTimelineDoesNotRetainADetachedLayer() {
        let timeline = GlassBorderPresentationTimeline()
        weak var released: NSObject?
        autoreleasepool {
            let layer = NSObject()
            released = layer
            timeline.recordCommit(100.02, for: layer)
        }
        XCTAssertNil(released)
    }

    func testInvalidOrBackwardRecordedTimesCannotPoisonAnEstablishedTarget() {
        let layer = NSObject()
        let timeline = GlassBorderPresentationTimeline()
        timeline.recordCommit(100.02, for: layer)
        for timestamp in [99, Double.nan, .infinity] {
            timeline.recordCommit(timestamp, for: layer)
            XCTAssertEqual(timeline.target(for: layer, prediction: nil, now: 100.001), 100.02.nextUp)
        }
    }
}
