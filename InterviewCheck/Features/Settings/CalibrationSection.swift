import InterviewCheckKit
import SwiftUI

/// Tunes the signal weights from the interviewer's verdicts in Reports.
struct CalibrationSection: View {
    @ObservedObject private var settings = DetectorSettings.shared
    @State private var labels: [LabeledAnswer] = []
    @State private var result: WeightTuner.Result?
    @State private var problem: String?
    @State private var isTuning = false

    var body: some View {
        Section {
            let assisted = labels.filter(\.wasAIAssisted).count
            LabeledContent("Your verdicts", value: "\(labels.count) (\(assisted) AI-assisted, \(labels.count - assisted) own)")
            LabeledContent("Current weights", value: describe(settings.weights))
            HStack {
                Button(isTuning ? "Tuning\u{2026}" : "Tune Weights From My Verdicts") { tune() }
                    .disabled(isTuning)
                Button("Reset to Defaults") {
                    settings.weights = .default
                    result = nil
                }
                .disabled(settings.weights == .default)
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            if let result {
                Text("Agreement with your verdicts: \(percent(result.baselineAccuracy)) now, \(percent(result.accuracy)) with \(describe(result.weights)).")
                Button("Apply These Weights") {
                    settings.weights = result.weights
                    self.result = nil
                }
                .disabled(result.accuracy <= result.baselineAccuracy)
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("Mark answers in Reports as their own or AI-assisted after your follow-ups. With \(WeightTuner.minimumLabels)+ verdicts (at least \(WeightTuner.minimumPerClass) of each), the weights can be tuned to how your candidates actually behave.")
        }
        .onAppear { labels = SessionDatabase.shared.loadLabeledAnswers() }
    }

    private func tune() {
        labels = SessionDatabase.shared.loadLabeledAnswers()
        let current = settings.weights
        let snapshot = labels
        isTuning = true
        problem = nil
        result = nil
        Task.detached(priority: .userInitiated) {
            let outcome = WeightTuner.tune(snapshot, starting: current)
            await MainActor.run {
                isTuning = false
                switch outcome {
                case .success(let tuned): result = tuned
                case .failure(.notEnoughLabels(let have, let need)): problem = "\(have) verdicts so far; \(need) are needed."
                case .failure(.needBothKinds(let genuine, let assisted)):
                    problem = "Needs at least \(WeightTuner.minimumPerClass) of each kind (have \(assisted) AI-assisted, \(genuine) own)."
                }
            }
        }
    }

    private func describe(_ weights: CheatScoreWeights) -> String {
        "timing \(Int(weights.timing * 100)), fluency \(Int(weights.fluency * 100)), match \(Int(weights.similarity * 100)), review \(Int(weights.judge * 100))"
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
