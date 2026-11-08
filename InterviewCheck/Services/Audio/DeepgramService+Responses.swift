import AVFoundation
import Combine
import CoreMedia
import Foundation

extension DeepgramService {
    // MARK: - Receiving Messages

    func startReceiving(socket: URLSessionWebSocketTask?) {
        guard let socket else { return }
        socket.receive { [weak self] result in
            guard let self, self.stateLock.withLock({ self.webSocket === socket }) else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message, socket: socket)
                // Continue receiving
                self.startReceiving(socket: socket)

            case .failure(let error):
                if DeepgramStreamCore.isCancellation(error) {
                    self.logDebug("Receive cancelled")
                    return
                }
                let summary = DeepgramStreamCore.errorSummary(error)
                self.logDebug("Receive error: \(summary)")
                self.handleDisconnection(error: error, summary: summary, expectedSocket: socket)
            }
        }
    }

    func handleMessage(_ message: URLSessionWebSocketTask.Message, socket: URLSessionWebSocketTask) {
        ndjsonInboundMessageCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - ndjsonLastInboundLogTime >= 5.0 {
            ndjsonLastInboundLogTime = now
            // #region agent log
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H2",
                location: "DeepgramService.handleMessage",
                message: "deepgram_inbound_messages",
                data: [
                    "count": ndjsonInboundMessageCount,
                    "connectionState": connectionState.debugLabel
                ]
            )
            // #endregion
        }

        switch message {
        case .string(let text):
            parseAndEmitResponse(text, socket: socket)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseAndEmitResponse(text, socket: socket)
            }
        @unknown default:
            logDebug("Unknown message type")
        }
    }

    func parseAndEmitResponse(_ jsonString: String, socket: URLSessionWebSocketTask? = nil) {
        let epoch = stateLock.withLock { connectionEpoch }
        if let errorMessage = DeepgramStreamCore.parseDeepgramError(jsonString) {
            // #region agent log
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H2",
                location: "DeepgramService.parseAndEmitResponse",
                message: "deepgram_error_message",
                data: [
                    "error": errorMessage
                ]
            )
            // #endregion
            updateState(.error(errorMessage))
            return
        }

        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)

            if let utterances = response.utterances, !utterances.isEmpty {
                var segments: [DeepgramTranscriptSegment] = []
                var latestSpeaker = stateLock.withLock { lastSpeakerId }

                for utterance in utterances {
                    let transcript = utterance.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !transcript.isEmpty else { continue }

                    let inferredSpeaker = utterance.speaker ?? DeepgramStreamCore.inferSpeakerId(from: utterance.words)
                    let speaker = inferredSpeaker ?? latestSpeaker
                    if let speaker {
                        latestSpeaker = speaker
                    }

                    let segment = DeepgramTranscriptSegment(
                        text: transcript,
                        speaker: speaker,
                        startTime: utterance.start,
                        endTime: utterance.end,
                        isFinal: true,
                        confidence: utterance.confidence,
                        words: utterance.words ?? []
                    )
                    segments.append(segment)
                }

                stateLock.withLock {
                    if connectionEpoch == epoch { lastSpeakerId = latestSpeaker }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stateLock.withLock({ self.connectionEpoch == epoch }) else { return }
                    self.currentSpeaker = latestSpeaker
                    for segment in segments {
                        self.onTranscriptReceived?(segment)
                    }
                }
                return
            }

            // Skip non-transcript messages
            guard let channel = response.channel,
                  let alternative = channel.alternatives.first else {
                return
            }

            let transcript = alternative.transcript
            guard !transcript.isEmpty else { return }

            // Extract speaker using majority vote over word-level speakers
            let inferredSpeaker = DeepgramStreamCore.inferSpeakerId(from: alternative.words)
            let speaker = stateLock.withLock { () -> Int? in
                let speaker = inferredSpeaker ?? lastSpeakerId
                if let speaker, connectionEpoch == epoch { lastSpeakerId = speaker }
                return speaker
            }

            // Create segment
            let segment = DeepgramTranscriptSegment(
                text: transcript,
                speaker: speaker,
                startTime: response.start ?? 0,
                endTime: (response.start ?? 0) + (response.duration ?? 0),
                isFinal: response.isFinal ?? false,
                confidence: alternative.confidence,
                words: alternative.words ?? []
            )

            // Emit on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stateLock.withLock({ self.connectionEpoch == epoch }) else { return }
                self.currentSpeaker = speaker
                self.onTranscriptReceived?(segment)
            }

        } catch {
            // Silently ignore parse errors for non-transcript messages
            if jsonString.contains("\"type\":\"Results\"") {
                logDebug("Parse error: \(DeepgramStreamCore.errorSummary(error))")
            }
        }
    }
}
// MARK: - Debug helpers

private extension DeepgramConnectionState {
    var debugLabel: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let message): return "error:\(message)"
        }
    }
}
