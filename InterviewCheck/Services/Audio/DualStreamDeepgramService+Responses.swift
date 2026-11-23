import AVFoundation
import Combine
import CoreMedia
import Foundation

extension DualStreamDeepgramService {
    func startReceiving(socket: URLSessionWebSocketTask?, source: AudioSource) {
        guard let socket else { return }
        socket.receive { [weak self] result in
            guard let self, self.isCurrentSocket(socket, source: source) else { return }

            switch result {
            case .success(let message):
                self.incrementInboundMessages(source: source)
                self.markReadyIfNeeded(source)
                self.handleMessage(message, source: source, socket: socket)
                // Continue receiving
                self.startReceiving(socket: socket, source: source)

            case .failure(let error):
                if DeepgramStreamCore.isCancellation(error) {
                    self.logDebug("[\(source.displayName)] Receive cancelled")
                    return
                }
                let summary = DeepgramStreamCore.errorSummary(error)
                self.logDebug("[\(source.displayName)] Receive error: \(summary)")
                self.updateMetricError(source: source, message: summary)
                self.handleDisconnection(source: source, error: error, summary: summary, expectedSocket: socket)
            }
        }
    }

    func handleMessage(_ message: URLSessionWebSocketTask.Message, source: AudioSource, socket: URLSessionWebSocketTask) {
        switch message {
        case .string(let text):
            parseAndEmitResponse(text, source: source, socket: socket)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseAndEmitResponse(text, source: source, socket: socket)
            }
        @unknown default:
            logDebug("[\(source.displayName)] Unknown message type")
        }
    }

    func parseAndEmitResponse(
        _ jsonString: String,
        source: AudioSource,
        socket: URLSessionWebSocketTask? = nil
    ) {
        let epoch = connectionEpoch(for: source)
        if let errorMessage = DeepgramStreamCore.parseDeepgramError(jsonString) {
            logDebug("[\(source.displayName)] Error: \(errorMessage)")
            handleErrorMessage(source: source, message: errorMessage, expectedSocket: socket)
            return
        }

        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            let answersFinalize = response.fromFinalize == true

            guard let channel = response.channel,
                  let alternative = channel.alternatives.first,
                  !alternative.transcript.isEmpty else {
                if answersFinalize { DispatchQueue.main.async { [weak self] in self?.resolveFinalize(source) } }
                return
            }

            let transcript = alternative.transcript
            updateTranscriptMetrics(source: source)

            // Extract speaker using majority vote over word-level speakers
            let inferredSpeaker = DeepgramStreamCore.inferSpeakerId(from: alternative.words)
            let speaker = stateLock.withLock { () -> Int? in
                let speaker = inferredSpeaker ?? lastSpeakerBySource[source]
                if let speaker { lastSpeakerBySource[source] = speaker }
                return speaker
            }

            let segment = DeepgramTranscriptSegment(
                text: transcript,
                speaker: speaker,
                startTime: response.start ?? 0,
                endTime: (response.start ?? 0) + (response.duration ?? 0),
                isFinal: response.isFinal ?? false,
                confidence: alternative.confidence,
                words: alternative.words ?? []
            )

            let timed = segment.isFinal ? timedWords(segment.words, source: source) : nil

            // Resolve the callback when delivering. Teardown or reconnect can
            // invalidate a queued frame after parsing but before the main queue runs.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // After the words are delivered: the end of the interview waits for them.
                defer { if answersFinalize { self.resolveFinalize(source) } }
                guard self.connectionEpoch(for: source) == epoch else { return }
                let (callback, timedCallback) = self.stateLock.withLock {
                    (source == .microphone ? self.onMicTranscript : self.onSystemTranscript,
                     self.onFinalTimedWords)
                }
                callback?(segment)
                if let timed { timedCallback?(timed) }
            }

        } catch {
            // Silently ignore parse errors for non-transcript messages
            if jsonString.contains("\"type\":\"Results\"") {
                logDebug("[\(source.displayName)] Parse error: \(DeepgramStreamCore.errorSummary(error))")
            }
        }
    }

    /// Maps a final result's word offsets onto the host clock. Nil before
    /// any audio was sent on this connection.
    func timedWords(_ words: [DeepgramWord], source: AudioSource) -> DeepgramTimedWords? {
        let streamClock = clock(for: source)
        var mapped: [DeepgramTimedWords.Word] = []
        for word in words {
            guard let start = streamClock.hostTime(forOffset: word.start),
                  let end = streamClock.hostTime(forOffset: word.end) else { return nil }
            mapped.append(.init(word: word, hostStart: start, hostEnd: max(end, start)))
        }
        guard !mapped.isEmpty else { return nil }
        return DeepgramTimedWords(source: source, words: mapped, clockBreaks: streamClock.breakCount,
                                  connection: connectionEpoch(for: source))
    }
}

/// Final words from one Deepgram result, placed on the host clock.
struct DeepgramTimedWords {
    struct Word {
        let word: DeepgramWord
        let hostStart: TimeInterval
        let hostEnd: TimeInterval
    }

    let source: AudioSource
    let words: [Word]
    /// How often this connection's audio was not contiguous so far.
    let clockBreaks: Int
    /// Which socket delivered it; a new value means the stream reconnected
    /// (and its clock and break count started over).
    var connection: UInt64 = 0
}
