import XCTest
@testable import memanager

final class GlassBorderFramePredictionTests: XCTestCase {
    func testRegularTargetFitsTheObservedIntervalAndThirtyHertzBudget() {
        XCTAssertEqual(GlassBorderFramePrediction(timestamp: 100.02, frameInterval: 1.0 / 30).time(at: 100), 100.02)
        XCTAssertNil(GlassBorderFramePrediction(timestamp: 100.02, frameInterval: 1.0 / 60).time(at: 100))
        XCTAssertNil(GlassBorderFramePrediction(timestamp: 100.04, frameInterval: 1).time(at: 100))
    }

    func testLateOrInvalidPredictionsUseTheCurrentAcquisitionPhase() {
        let prediction = GlassBorderFramePrediction(timestamp: 100.02, frameInterval: 1.0 / 30)
        XCTAssertNil(prediction.time(at: 100.03))
        XCTAssertNil(prediction.time(at: .infinity))
        for timestamp in [100, 99, Double.nan, .infinity] {
            XCTAssertNil(GlassBorderFramePrediction(timestamp: timestamp, frameInterval: 1.0 / 30).time(at: 100))
        }
        for interval in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(GlassBorderFramePrediction(timestamp: 100.02, frameInterval: interval).time(at: 100))
        }
    }
}
