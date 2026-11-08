import XCTest
@testable import memanager

final class SettingsSliderEditingStateTests: XCTestCase {
    func testDragPublishesOnlyItsFinalValueOnce() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        for value in 13...112 {
            XCTAssertNil(editing.update(Double(value), committed: 12, range: 0...200))
            XCTAssertEqual(editing.displayedValue(committed: 12), Double(value))
        }
        editing.begin(committed: 12)
        XCTAssertEqual(editing.displayedValue(committed: 12), 112)
        XCTAssertEqual(editing.end(committed: 12, range: 0...200), 112)
        XCTAssertNil(editing.end(committed: 112, range: 0...200))
        XCTAssertEqual(editing.displayedValue(committed: 112), 112)
    }

    func testReturningToTheOriginalValueDoesNotPublish() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(24, committed: 12, range: 2...48))
        XCTAssertNil(editing.update(12, committed: 12, range: 2...48))
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        editing.begin(committed: 12)
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
    }

    func testDiscreteChangesPublishImmediatelyAndReadTheCommittedValue() {
        var editing = SettingsSliderEditingState<Double>()
        XCTAssertEqual(editing.update(13, committed: 12, range: 2...48), 13)
        XCTAssertEqual(editing.displayedValue(committed: 13), 13)
        XCTAssertNil(editing.update(13, committed: 13, range: 2...48))
        XCTAssertEqual(editing.update(14, committed: 13, range: 2...48), 14)
        XCTAssertEqual(editing.displayedValue(committed: 14), 14)
    }

    func testExternalResetWinsOverTheUnreleasedDraft() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 20)
        XCTAssertNil(editing.update(30, committed: 20, range: 2...48))
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        XCTAssertEqual(editing.update(13, committed: 12, range: 2...48), 13)
    }

    func testDragStaysInvalidAfterObservingAnExternalChange() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 20)
        XCTAssertNil(editing.update(30, committed: 20, range: 2...48))
        XCTAssertNil(editing.update(31, committed: 12, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        XCTAssertNil(editing.update(32, committed: 20, range: 2...48))
        XCTAssertNil(editing.end(committed: 20, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 20), 20)
    }

    func testInvalidationSuppressesRemainingDragEventsUntilRelease() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 20)
        XCTAssertNil(editing.update(30, committed: 20, range: 2...48))
        editing.invalidate()
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        for value in 31...40 {
            XCTAssertNil(editing.update(Double(value), committed: 12, range: 2...48))
            XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        }
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(24, committed: 12, range: 2...48))
        XCTAssertEqual(editing.end(committed: 12, range: 2...48), 24)
    }

    func testCancellationDiscardsTheDraftWhenControlsDisappear() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(30, committed: 12, range: 2...48))
        editing.cancel()
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        XCTAssertEqual(editing.update(13, committed: 12, range: 2...48), 13)
    }

    func testAReplacementMaterialStartsWithoutThePreviousDraft() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(30, committed: 12, range: 2...48))
        editing = SettingsSliderEditingState<Double>()
        XCTAssertEqual(editing.displayedValue(committed: 8), 8)
        XCTAssertNil(editing.end(committed: 8, range: 2...48))
        editing.begin(committed: 8)
        XCTAssertNil(editing.update(10, committed: 8, range: 2...48))
        XCTAssertEqual(editing.end(committed: 8, range: 2...48), 10)
    }

    func testDisablingMidDragAllowsANewDragWithoutAnOldReleaseCallback() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(30, committed: 12, range: 2...48))
        editing.invalidate() // The material first changes to None.
        editing.cancel() // Its retained controls become disabled.
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        // No end callback arrives for the disabled native slider.
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(24, committed: 12, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 12), 24)
        XCTAssertEqual(editing.end(committed: 12, range: 2...48), 24)
    }

    func testALateReleaseAfterDisablingCannotCommitTheCancelledDraft() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(30, committed: 12, range: 2...48))
        editing.cancel()
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        XCTAssertEqual(editing.update(13, committed: 12, range: 2...48), 13)
    }

    func testEqualValuedMaterialChangeInvalidatesDraftWithoutReplacingTheControl() {
        var editing = SettingsSliderEditingState<Double>()
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(30, committed: 12, range: 2...48))
        // Glass and Liquid both default to 12pt. A context change must win even
        // though neither the saved value nor the slider range changed.
        editing.invalidate()
        XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        XCTAssertNil(editing.update(31, committed: 12, range: 2...48))
        XCTAssertNil(editing.end(committed: 12, range: 2...48))
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(24, committed: 12, range: 2...48))
        XCTAssertEqual(editing.end(committed: 12, range: 2...48), 24)
    }

    func testValuesAreClampedAgainToTheCurrentRangeAtRelease() {
        var editing = SettingsSliderEditingState<Double>()
        XCTAssertEqual(editing.update(-100, committed: 12, range: 2...48), 2)
        XCTAssertEqual(editing.update(100, committed: 12, range: 2...48), 48)
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(100, committed: 12, range: 2...48))
        XCTAssertEqual(editing.displayedValue(committed: 12), 48)
        XCTAssertEqual(editing.end(committed: 12, range: 2...24), 24)
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(48, committed: 12, range: 2...48))
        XCTAssertNil(editing.end(committed: 12, range: 2...12))
    }

    func testNonfiniteInputCannotReplaceTheLastValidValue() {
        var editing = SettingsSliderEditingState<Double>()
        let invalid: [Double] = [.nan, .infinity, -.infinity]
        for value in invalid {
            XCTAssertNil(editing.update(value, committed: 12, range: 2...48))
            XCTAssertEqual(editing.displayedValue(committed: 12), 12)
        }
        editing.begin(committed: 12)
        XCTAssertNil(editing.update(24, committed: 12, range: 2...48))
        for value in invalid {
            XCTAssertNil(editing.update(value, committed: 12, range: 2...48))
            XCTAssertEqual(editing.displayedValue(committed: 12), 24)
        }
        XCTAssertEqual(editing.end(committed: 12, range: 2...48), 24)
    }

    func testWidthDragLeavesPersistedMaterialUntouchedUntilRelease() throws {
        try withStore { store in
            var configuration = try XCTUnwrap(store.load(for: .glass))
            let original = configuration
            var editing = SettingsSliderEditingState<Double>()
            var writes = 0
            editing.begin(committed: configuration.width)
            for sample in 1...100 {
                let proposed = 12 + 36 * Double(sample) / 100
                if let value = editing.update(proposed, committed: configuration.width, range: 2...48) {
                    configuration.width = value
                    configuration = try XCTUnwrap(store.save(configuration, for: .glass))
                    writes += 1
                }
                XCTAssertEqual(configuration, original)
                XCTAssertEqual(store.load(for: .glass), original)
            }
            XCTAssertEqual(writes, 0)
            configuration.width = try XCTUnwrap(editing.end(committed: configuration.width, range: 2...48))
            configuration = try XCTUnwrap(store.save(configuration, for: .glass))
            writes += 1
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(store.load(for: .glass)?.width, 48)
            XCTAssertEqual(store.load(for: .liquid), .liquidDefault)
        }
    }

    func testReleaseDisplaysTheValueNormalizedByTheMaterialStore() throws {
        try withStore { store in
            var configuration = try XCTUnwrap(store.load(for: .glass))
            var editing = SettingsSliderEditingState<Double>()
            editing.begin(committed: configuration.depth)
            XCTAssertNil(editing.update(30, committed: configuration.depth, range: 1...30))
            configuration.depth = try XCTUnwrap(editing.end(committed: configuration.depth, range: 1...30))
            configuration = try XCTUnwrap(store.save(configuration, for: .glass))
            XCTAssertLessThan(configuration.depth, 30)
            XCTAssertEqual(editing.displayedValue(committed: configuration.depth), configuration.depth)
            XCTAssertEqual(store.load(for: .glass)?.depth, configuration.depth)
        }
    }

    func testDraggingWidthNarrowerAndBackPreservesTheOriginalDepth() throws {
        try withStore { store in
            var configuration = try XCTUnwrap(store.save(.glassDefault, for: .glass))
            let original = configuration
            var editing = SettingsSliderEditingState<Double>()
            editing.begin(committed: configuration.width)
            for proposed in [2.0, original.width] {
                if let width = editing.update(proposed, committed: configuration.width, range: 2...48) {
                    configuration.width = width
                    configuration = try XCTUnwrap(store.save(configuration, for: .glass))
                }
                XCTAssertEqual(configuration, original)
                XCTAssertEqual(store.load(for: .glass), original)
            }
            XCTAssertNil(editing.end(committed: configuration.width, range: 2...48))
            XCTAssertEqual(store.load(for: .glass)?.depth, original.depth)
        }
    }

    private func withStore(_ body: (BorderShaderConfigurationStore) throws -> Void) throws {
        let suite = "SettingsSliderEditingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(BorderShaderConfigurationStore(defaults: defaults))
    }
}
