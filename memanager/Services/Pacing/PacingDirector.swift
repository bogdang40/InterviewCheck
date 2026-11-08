import Combine
import Foundation

/// The in-session conductor. Observes transcript entries, drives the sampler
/// every few seconds, and publishes a `PacingState` after two-tick hysteresis.
///
/// The director owns no UI and no LLM plumbing. Callers read `$state` and
/// decide what to do with it (prompt rewriting, UI indicator, debrief).
protocol PacingDirecting: AnyObject {
    var state: PacingState { get }
    var statePublisher: Published<PacingState>.Publisher { get }
    func ingest(entries: [TranscriptEntry])
    func evaluate(now: Date)
    func reset()
}

final class PacingDirector: ObservableObject, PacingDirecting {
    static let shared = PacingDirector()

    @Published private(set) var state: PacingState = .measuredBaseline
    var statePublisher: Published<PacingState>.Publisher { $state }

    private let sampler: PacingSampling
    private let evaluationInterval: TimeInterval
    private var latestEntries: [TranscriptEntry] = []
    private var pendingKind: PacingState.Kind?
    private var pendingTicks: Int = 0
    private let hysteresisThreshold: Int
    private var timerCancellable: AnyCancellable?

    init(
        sampler: PacingSampling = PacingSampler(),
        evaluationInterval: TimeInterval = 4.0,
        hysteresisThreshold: Int = 2
    ) {
        self.sampler = sampler
        self.evaluationInterval = evaluationInterval
        self.hysteresisThreshold = hysteresisThreshold
    }

    func start() {
        stop()
        timerCancellable = Timer.publish(every: evaluationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.evaluate(now: date)
            }
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    func ingest(entries: [TranscriptEntry]) {
        latestEntries = entries
    }

    func evaluate(now: Date) {
        let reading = sampler.evaluate(entries: latestEntries, now: now)
        let kind = classify(reading: reading)
        applyHysteresis(kind: kind, confidence: confidence(for: kind, reading: reading))
    }

    func reset() {
        latestEntries = []
        pendingKind = nil
        pendingTicks = 0
        state = .measuredBaseline
    }

    // MARK: - Classification

    private func classify(reading: PacingReading) -> PacingState.Kind {
        if reading.trailingSilenceSeconds > 12 {
            return .stalled
        }
        if let wpm = reading.interviewerWordsPerMinute,
           wpm >= 190
        {
            return .decisive
        }
        let interruptions = max(0, reading.interviewerUtteranceCount - 1) // proxy: more utterances in 60s ~= more interruptions
        if reading.interviewerQuestionCount >= 3 {
            return .decisive
        }
        if interruptions >= 2, reading.interviewerUtteranceCount >= 3 {
            return .decisive
        }
        if let gap = reading.avgInterviewerUtteranceGapSeconds,
           gap >= 4,
           let candidateWPM = reading.candidateWordsPerMinute,
           candidateWPM > 110
        {
            return .expansive
        }
        return .measured
    }

    private func confidence(for kind: PacingState.Kind, reading: PacingReading) -> Double {
        guard reading.sampleSize > 0 else { return 0 }
        let density = min(1.0, Double(reading.sampleSize) / 8.0)
        switch kind {
        case .decisive:
            if let wpm = reading.interviewerWordsPerMinute {
                let wpmComponent = min(1.0, max(0, (wpm - 140) / 120))
                return min(1.0, 0.5 * wpmComponent + 0.5 * density)
            }
            return density
        case .measured:
            return density
        case .expansive:
            return density
        case .stalled:
            return min(1.0, reading.trailingSilenceSeconds / 20)
        }
    }

    private func applyHysteresis(kind: PacingState.Kind, confidence: Double) {
        if kind == state.kind {
            pendingKind = nil
            pendingTicks = 0
            state = kind.makeState(confidence: confidence)
            return
        }
        if pendingKind == kind {
            pendingTicks += 1
        } else {
            pendingKind = kind
            pendingTicks = 1
        }
        if pendingTicks >= hysteresisThreshold {
            state = kind.makeState(confidence: confidence)
            pendingKind = nil
            pendingTicks = 0
        }
    }
}

private extension PacingState.Kind {
    func makeState(confidence: Double) -> PacingState {
        switch self {
        case .decisive: return .decisive(confidence: confidence)
        case .measured: return .measured(confidence: confidence)
        case .expansive: return .expansive(confidence: confidence)
        case .stalled: return .stalled(confidence: confidence)
        }
    }
}
