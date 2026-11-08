import XCTest
@testable import memanager

final class SettingsSliderQuantizationTests: XCTestCase {
    func testFineAppearanceControlsAvoidNativeTickLayouts() throws {
        for (range, step) in [(1.0...2.2, 0.001), (0...0.06, 0.001),
                              (0...0.08, 0.001), (2...48, 1.0), (1...10, 0.1)] {
            XCTAssertTrue(try quantization(range, step: step).usesContinuousSlider)
        }
        XCTAssertFalse(try quantization(10...24, step: 1).usesContinuousSlider)
        XCTAssertFalse(try quantization(0.1...2, step: 0.1).usesContinuousSlider)
        XCTAssertFalse(try quantization(0...31, step: 1).usesContinuousSlider)
        XCTAssertTrue(try quantization(0...32, step: 1).usesContinuousSlider)
    }

    func testSnappingUsesTheLowerBoundAndRetainsFinePrecision() throws {
        let ior = try quantization(1...2.2, step: 0.001)
        XCTAssertEqual(try XCTUnwrap(ior.snapped(1.3334)), 1.333, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(ior.snapped(1.3336)), 1.334, accuracy: 0.000000001)
        let offset = try quantization(0.003...0.1, step: 0.01)
        XCTAssertEqual(try XCTUnwrap(offset.snapped(0.019)), 0.023, accuracy: 0.000000001)
        let float = try XCTUnwrap(SettingsSliderQuantization<Float>(range: 1...2.2, step: 0.001))
        XCTAssertEqual(try XCTUnwrap(float.snapped(1.3336)), 1.334, accuracy: 0.000001)
    }

    func testRangeEndpointsStayReachableIncludingAnOffGridUpperBound() throws {
        let values = try quantization(0.003...0.1, step: 0.01)
        XCTAssertEqual(values.snapped(-100), 0.003)
        XCTAssertEqual(values.snapped(100), 0.1)
        XCTAssertEqual(values.snapped(0.1), 0.1)
        XCTAssertEqual(values.adjusted(0.1, increment: true), 0.1)
        XCTAssertEqual(try XCTUnwrap(values.adjusted(0.1, increment: false)), 0.093, accuracy: 0.000000001)
        XCTAssertEqual(values.adjusted(0.003, increment: false), 0.003)
        XCTAssertEqual(values.adjusted(0.093, increment: true), 0.1)
    }

    func testArrowAndAccessibilityAdjustmentsAdvanceOneStepWithoutDrift() throws {
        let values = try quantization(1...2.2, step: 0.001)
        var current = 1.0
        for index in 1...1200 {
            current = try XCTUnwrap(values.adjusted(current, increment: true))
            XCTAssertEqual(current, 1 + Double(index) * 0.001, accuracy: 0.000000001)
        }
        for index in (0..<1200).reversed() {
            current = try XCTUnwrap(values.adjusted(current, increment: false))
            XCTAssertEqual(current, 1 + Double(index) * 0.001, accuracy: 0.000000001)
        }
        XCTAssertEqual(try XCTUnwrap(values.adjusted(1.3334, increment: true)), 1.334, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(values.adjusted(1.3334, increment: false)), 1.333, accuracy: 0.000000001)
    }

    func testInvalidNumbersCannotReachTheBinding() throws {
        XCTAssertNil(SettingsSliderQuantization<Double>(range: 0...1, step: 0))
        XCTAssertNil(SettingsSliderQuantization<Double>(range: 0...1, step: -1))
        XCTAssertNil(SettingsSliderQuantization<Double>(range: 0...1, step: .nan))
        XCTAssertNil(SettingsSliderQuantization<Double>(range: 0...1, step: .infinity))
        let values = try quantization(1...2.2, step: 0.001)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(values.snapped(invalid))
            XCTAssertNil(values.adjusted(invalid, increment: true))
            XCTAssertNil(values.adjusted(invalid, increment: false))
        }
    }

    func testQuantizedDragStillCommitsOnlyOnReleaseAndDiscreteActionsCommitImmediately() throws {
        let values = try quantization(1...2.2, step: 0.001)
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 1.333)
        for proposal in [1.3342, 1.3351, 1.3364] {
            XCTAssertNil(editing.update(try XCTUnwrap(values.snapped(proposal)),
                committed: 1.333, range: values.range))
        }
        XCTAssertEqual(try XCTUnwrap(editing.end(committed: 1.333, range: values.range)), 1.336, accuracy: 0.000000001)
        let increment = try XCTUnwrap(values.adjusted(1.336, increment: true))
        XCTAssertEqual(try XCTUnwrap(editing.update(increment, committed: 1.336, range: values.range)), 1.337, accuracy: 0.000000001)
    }

    private func quantization(_ range: ClosedRange<Double>, step: Double) throws -> SettingsSliderQuantization<Double> {
        try XCTUnwrap(SettingsSliderQuantization(range: range, step: step))
    }
}
