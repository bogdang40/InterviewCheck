import Foundation

/// One scored answer the interviewer has labeled.
public struct LabeledAnswer: Equatable {
    public let components: ScoreComponents
    /// True when the interviewer judged the answer AI-assisted.
    public let wasAIAssisted: Bool

    public init(components: ScoreComponents, wasAIAssisted: Bool) {
        self.components = components
        self.wasAIAssisted = wasAIAssisted
    }
}

/// Finds signal weights that best separate the interviewer's labels.
///
/// A small grid search: every weight from 0 to 0.6 in steps of 0.05, scored
/// by balanced accuracy at a 50% cut-off (so a few AI-assisted labels among
/// many genuine ones still count). Ties go to the weights closest to the
/// defaults, so a handful of labels nudges rather than overturns them.
public enum WeightTuner {
    public static let minimumLabels = 10
    public static let minimumPerClass = 3

    public struct Result: Equatable {
        public let weights: CheatScoreWeights
        public let accuracy: Double
        public let baselineAccuracy: Double
        public let labelCount: Int
    }

    public enum Problem: Error, Equatable {
        case notEnoughLabels(have: Int, need: Int)
        case needBothKinds(genuine: Int, assisted: Int)
    }

    public static func tune(_ labels: [LabeledAnswer], starting base: CheatScoreWeights = .default) -> Swift.Result<Result, Problem> {
        let assisted = labels.filter(\.wasAIAssisted).count
        let genuine = labels.count - assisted
        guard labels.count >= minimumLabels else { return .failure(.notEnoughLabels(have: labels.count, need: minimumLabels)) }
        guard assisted >= minimumPerClass, genuine >= minimumPerClass else {
            return .failure(.needBothKinds(genuine: genuine, assisted: assisted))
        }

        let steps = stride(from: 0.0, through: 0.6, by: 0.05).map { ($0 * 100).rounded() / 100 }
        var best = base
        var bestAccuracy = accuracy(labels, weights: base)
        var bestDistance = 0.0
        let baseline = bestAccuracy
        for timing in steps {
            for fluency in steps {
                for similarity in steps {
                    for judge in steps where timing + fluency + similarity + judge > 0 {
                        var candidate = base
                        candidate.timing = timing
                        candidate.fluency = fluency
                        candidate.similarity = similarity
                        candidate.judge = judge
                        let score = accuracy(labels, weights: candidate)
                        let distance = abs(timing - base.timing) + abs(fluency - base.fluency)
                            + abs(similarity - base.similarity) + abs(judge - base.judge)
                        if score > bestAccuracy + 1e-9 || (abs(score - bestAccuracy) <= 1e-9 && distance < bestDistance) {
                            best = candidate
                            bestAccuracy = score
                            bestDistance = distance
                        }
                    }
                }
            }
        }
        return .success(Result(weights: best, accuracy: bestAccuracy, baselineAccuracy: baseline, labelCount: labels.count))
    }

    /// Mean of the accuracy on AI-assisted labels and on genuine labels.
    public static func accuracy(_ labels: [LabeledAnswer], weights: CheatScoreWeights, cutoff: Double = 0.5) -> Double {
        let assisted = labels.filter(\.wasAIAssisted)
        let genuine = labels.filter { !$0.wasAIAssisted }
        guard !assisted.isEmpty, !genuine.isEmpty else { return 0 }
        let hit = assisted.filter { CheatScorer.blend($0.components, weights: weights) >= cutoff }.count
        let pass = genuine.filter { CheatScorer.blend($0.components, weights: weights) < cutoff }.count
        return (Double(hit) / Double(assisted.count) + Double(pass) / Double(genuine.count)) / 2
    }
}
