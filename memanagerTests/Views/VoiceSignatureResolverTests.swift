import XCTest
@testable import memanager

final class VoiceSignatureResolverTests: XCTestCase {
    func testStrictnessPresetRoundTripsAndFallsBackToCustom() {
        for preset in VoiceStrictnessPreset.allCases where preset != .custom {
            let thresholds = preset.thresholds!
            XCTAssertEqual(VoiceStrictnessPreset.from(enter: thresholds.enter, exit: thresholds.exit), preset)
        }
        XCTAssertEqual(VoiceStrictnessPreset.from(enter: 0.80, exit: 0.70), .custom)
        XCTAssertNil(VoiceStrictnessPreset.custom.thresholds)
    }

    func testExitThresholdIsClampedBelowEnter() {
        XCTAssertEqual(VoiceStrictnessPreset.clampedExit(0.9, enter: 0.85), 0.8, accuracy: 0.0001)
        XCTAssertEqual(VoiceStrictnessPreset.clampedExit(0.7, enter: 0.85), 0.7, accuracy: 0.0001)
    }

    func testScoreToneFollowsThresholds() {
        XCTAssertEqual(LiveTestScoreTone.tone(score: 0.9, enter: 0.85, exit: 0.75), .success)
        XCTAssertEqual(LiveTestScoreTone.tone(score: 0.8, enter: 0.85, exit: 0.75), .warning)
        XCTAssertEqual(LiveTestScoreTone.tone(score: 0.5, enter: 0.85, exit: 0.75), .critical)
    }

    func testLevelQuality() {
        XCTAssertEqual(VoiceLevelQuality(level: 0.05), .quiet)
        XCTAssertEqual(VoiceLevelQuality(level: 0.4), .good)
        XCTAssertEqual(VoiceLevelQuality(level: 0.95), .loud)
        XCTAssertEqual(VoiceLevelQuality.quiet.tone, .warning)
        XCTAssertEqual(VoiceLevelQuality.good.label, "Good")
    }

    func testGaugeGeometryRunsLeftToRightOverTheTop() {
        let left = LiveTestGaugeGeometry.markerOffset(value: 0, radius: 100)
        XCTAssertEqual(left.x, -100, accuracy: 0.001)
        XCTAssertEqual(left.y, 0, accuracy: 0.001)
        let top = LiveTestGaugeGeometry.markerOffset(value: 0.5, radius: 100)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertEqual(top.y, -100, accuracy: 0.001)
        let right = LiveTestGaugeGeometry.markerOffset(value: 1, radius: 100)
        XCTAssertEqual(right.x, 100, accuracy: 0.001)
        XCTAssertEqual(right.y, 0, accuracy: 0.001)
        XCTAssertEqual(LiveTestGaugeGeometry.arcEnd(for: 1), 0.75, accuracy: 0.001)
        XCTAssertEqual(LiveTestGaugeGeometry.arcEnd(for: 2), 0.75, accuracy: 0.001)
    }

    func testScoreHistoryKeepsCapacity() {
        var history = ScoreHistory(capacity: 3)
        for score in [0.1, 0.2, 0.3, 0.4] as [Float] { history.append(score) }
        XCTAssertEqual(history.scores, [0.2, 0.3, 0.4])
        XCTAssertEqual(ScoreHistory(capacity: 2, scores: [0.1, 0.2, 0.3]).scores, [0.2, 0.3])
        history.removeAll()
        XCTAssertTrue(history.scores.isEmpty)
    }

    func testVoiceKeyStatusMapping() {
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .loading), .loading)
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .saving), .saving)
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .unavailable("denied")), .unavailable("denied"))
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .configured), .configured)
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .notConfigured), .missing)
        XCTAssertEqual(VoiceKeyStatusMapper.status(for: .saveFailed("x")), .failed("x"))
    }
}
