import XCTest
@testable import InterviewCheckKit

final class WeightTunerTests: XCTestCase {
    /// In these labels only similarity tells the two kinds apart; timing is noise.
    private func labels() -> [LabeledAnswer] {
        (0..<12).map { index in
            let assisted = index % 2 == 0
            return LabeledAnswer(
                components: ScoreComponents(timing: index % 3 == 0 ? 0.9 : 0.2, fluency: 0.5,
                                            similarity: assisted ? 0.85 : 0.1, judge: nil),
                wasAIAssisted: assisted)
        }
    }

    func testTuningLearnsWhichSignalSeparatesTheLabels() throws {
        let result = try WeightTuner.tune(labels()).get()
        XCTAssertGreaterThan(result.accuracy, result.baselineAccuracy)
        XCTAssertEqual(result.accuracy, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(result.weights.similarity, result.weights.timing)
        XCTAssertEqual(result.labelCount, 12)
    }

    func testRefusesTooFewLabelsOrOneSidedLabels() {
        XCTAssertEqual(WeightTuner.tune(Array(labels().prefix(4))), .failure(.notEnoughLabels(have: 4, need: 10)))
        let oneSided = labels().map { LabeledAnswer(components: $0.components, wasAIAssisted: false) }
        XCTAssertEqual(WeightTuner.tune(oneSided), .failure(.needBothKinds(genuine: 12, assisted: 0)))
    }

    func testBlendIgnoresMissingSignals() {
        let components = ScoreComponents(timing: 1, fluency: nil, similarity: 0, judge: nil)
        var weights = CheatScoreWeights.default
        weights.timing = 0.5
        weights.similarity = 0.5
        XCTAssertEqual(CheatScorer.blend(components, weights: weights), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CheatScorer.blend(ScoreComponents(), weights: weights), 0)
    }
}
