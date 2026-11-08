import AVFoundation
import Foundation
import Speech

/// One live SpeechAnalyzer transcription stream (either the microphone or the
/// system audio side of a session).
///
/// Owns the analyzer, its transcriber module, the input continuation, and the
/// per stream format converter. Emits `DeepgramTranscriptSegment` values on the
/// main queue: volatile results as interim segments (isFinal false), finalized
/// results as final segments, mirroring the Deepgram streaming contract.
@available(macOS 26.0, *)
final class AppleAnalyzerStreamTranscriber {
    private let source: AudioSource
    private let locale: Locale
    private let contextualStrings: [String]
    private let mapper: AppleAnalyzerSegmentMapper

    private var analyzer: SpeechAnalyzer?
    private var converter: AppleAnalyzerAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var isStopped = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private let maxPendingBuffers = 128

    var onSegment: ((DeepgramTranscriptSegment) -> Void)?
    var onStateChange: ((DeepgramConnectionState) -> Void)?

    init(source: AudioSource, locale: Locale, contextualStrings: [String] = []) {
        self.source = source
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.mapper = AppleAnalyzerSegmentMapper(source: source)
    }

    func start() {
        emitState(.connecting)
        startTask = Task { [weak self] in
            await self?.startInternal()
        }
    }

    /// Safe to call from the audio tap / sample handler thread for this stream.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard !isStopped else {
            stateLock.unlock()
            return
        }
        guard let converter, let continuation = inputContinuation else {
            if pendingBuffers.count < maxPendingBuffers {
                pendingBuffers.append(buffer)
            }
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        if let converted = converter.convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func stop() {
        stateLock.lock()
        isStopped = true
        pendingBuffers.removeAll()
        let continuation = inputContinuation
        inputContinuation = nil
        stateLock.unlock()

        startTask?.cancel()
        continuation?.finish()

        let analyzer = self.analyzer
        self.analyzer = nil
        let resultsTask = self.resultsTask
        self.resultsTask = nil

        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            resultsTask?.cancel()
        }
        emitState(.disconnected)
    }

    private func startInternal() async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            emitState(.error("No compatible audio format for the speech model"))
            return
        }
        guard !Task.isCancelled else { return }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )

        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            emitState(.error("Speech model preparation failed: \(error.localizedDescription)"))
            return
        }
        guard !Task.isCancelled else { return }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handleResult(result)
                }
            } catch is CancellationError {
                // Orderly shutdown.
            } catch {
                self?.emitStateIfRunning(.error("Transcription stream failed: \(error.localizedDescription)"))
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(512)
        )

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            resultsTask?.cancel()
            resultsTask = nil
            emitState(.error("Speech analyzer failed to start: \(error.localizedDescription)"))
            return
        }

        self.analyzer = analyzer
        let converter = AppleAnalyzerAudioConverter(targetFormat: format)

        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            continuation.finish()
            Task { await analyzer.cancelAndFinishNow() }
            return
        }
        self.converter = converter
        self.inputContinuation = continuation
        let backlog = pendingBuffers
        pendingBuffers.removeAll()
        stateLock.unlock()

        for buffered in backlog {
            if let converted = converter.convert(buffered) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        emitState(.connected)
    }

    private func handleResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let segment = mapper.segment(
            text: trimmed,
            confidence: Self.averageConfidence(result.text),
            startSeconds: result.range.start.seconds,
            endSeconds: result.range.end.seconds,
            isFinal: result.isFinal
        )
        DispatchQueue.main.async { [weak self] in
            self?.onSegment?(segment)
        }
    }

    static func averageConfidence(_ text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                total += value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    private func emitState(_ state: DeepgramConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func emitStateIfRunning(_ state: DeepgramConnectionState) {
        stateLock.lock()
        let stopped = isStopped
        stateLock.unlock()
        guard !stopped else { return }
        emitState(state)
    }
}
