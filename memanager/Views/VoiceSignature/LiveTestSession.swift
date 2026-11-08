import AVFoundation
import Combine
import Foundation

/// Drives one live recognition test: the recognition service, the
/// microphone tap, and the readings the view shows. Seedable so the view
/// can be rendered with data and no microphone.
@MainActor
final class LiveTestSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var currentLabel: SpeakerLabel = .unknown
    @Published private(set) var smoothedScore: Float = 0
    @Published private(set) var history = ScoreHistory()
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?

    let store: VoiceSignatureStore
    private var recognitionService: VoiceSignatureRecognitionService?
    private let tap = MicrophoneTap()
    private(set) var runID = UUID()

    init(store: VoiceSignatureStore = .shared) {
        self.store = store
    }

    /// A session showing sample readings without touching the microphone.
    static func seeded(
        store: VoiceSignatureStore = .shared,
        label: SpeakerLabel,
        score: Float,
        scores: [Float],
        audioLevel: Float,
        isRunning: Bool = true
    ) -> LiveTestSession {
        let session = LiveTestSession(store: store)
        session.currentLabel = label
        session.smoothedScore = score
        session.history = ScoreHistory(scores: scores)
        session.audioLevel = audioLevel
        session.isRunning = isRunning
        return session
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        let currentRun = UUID()
        runID = currentRun
        errorMessage = nil
        history.removeAll()

        let service = VoiceSignatureRecognitionService(
            store: store,
            config: SpeakerRecognitionConfig(
                thresholdEnterMe: store.thresholdEnterMe,
                thresholdExitMe: store.thresholdExitMe
            )
        )
        service.onLabelChanged = { [weak self] label in
            Task { @MainActor in
                guard let self, self.isRunning, self.runID == currentRun else { return }
                self.currentLabel = label
            }
        }
        service.onScoreSample = { [weak self, weak service] sample in
            Task { @MainActor in
                guard let self, self.isRunning, self.runID == currentRun else { return }
                self.smoothedScore = service?.smoothedScore ?? sample.score
                self.history.append(sample.score)
            }
        }
        service.onProcessingError = { [weak self] error in
            Task { @MainActor in self?.receiveProcessingError(error, from: currentRun) }
        }

        do {
            try service.start()
            recognitionService = service
            try tap.start { [weak self, weak service] buffer, hostTime in
                service?.processMicAudio(buffer: buffer, hostTime: hostTime)
                let level = MicrophoneTap.level(of: buffer)
                Task { @MainActor in
                    guard let self, self.isRunning, self.runID == currentRun else { return }
                    self.audioLevel = level
                }
            }
            isRunning = true
        } catch {
            tap.stop()
            service.stop()
            recognitionService = nil
            isRunning = false
            currentLabel = .unknown
            smoothedScore = 0
            audioLevel = 0
            errorMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        runID = UUID()
        tap.stop()
        recognitionService?.stop()
        recognitionService = nil
        isRunning = false
        currentLabel = .unknown
        smoothedScore = 0
        audioLevel = 0
    }

    func receiveProcessingError(_ error: Error, from failedRun: UUID) {
        guard isRunning, runID == failedRun else { return }
        stop()
        errorMessage = "Voice recognition failed: \(error.localizedDescription)"
    }
}
