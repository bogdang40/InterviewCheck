import Foundation

// MARK: - Deepgram Stream Core

/// Shared transport plumbing for the Deepgram streaming services.
///
/// Owns the pieces that were previously duplicated between `DeepgramService`
/// (legacy unified stream) and `DualStreamDeepgramService` (default dual
/// stream): configuration constants, WebSocket URL construction, error
/// parsing, speaker inference, error introspection, and the keep-alive
/// sender. Connection readiness semantics, reconnection policy, and
/// transcript handling intentionally remain in each service.
enum DeepgramStreamCore {

    // MARK: - Configuration

    enum Config {
        static let baseURL = "wss://api.deepgram.com/v1/listen"
        static let model = "nova-2"
        static let sampleRate = 48000  // Match UnifiedAudioMixer output
        static let channels = 1
        static let encoding = "linear16"
        static let keepAliveInterval: TimeInterval = 10
    }

    // MARK: - WebSocket URL

    /// Builds the Deepgram streaming URL.
    ///
    /// Query item order matches the historical per-service builders exactly.
    /// The `utterances` item is omitted entirely when `utterances` is false
    /// (it is never emitted as `utterances=false`), and when present it sits
    /// between `diarize` and `interim_results`, so both services' request
    /// URLs remain byte-identical to their previous inline builders.
    static func buildWebSocketURL(diarize: Bool, utterances: Bool) -> URL? {
        var components = URLComponents(string: Config.baseURL)
        var queryItems = [
            URLQueryItem(name: "model", value: Config.model),
            URLQueryItem(name: "encoding", value: Config.encoding),
            URLQueryItem(name: "sample_rate", value: String(Config.sampleRate)),
            URLQueryItem(name: "channels", value: String(Config.channels)),
            URLQueryItem(name: "diarize", value: diarize ? "true" : "false"),
        ]
        if utterances {
            queryItems.append(URLQueryItem(name: "utterances", value: "true"))
        }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
        ])
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - Response Parsing

    /// Extracts a human-readable error message from a Deepgram error frame,
    /// or returns nil when the payload is not an error frame.
    static func parseDeepgramError(_ jsonString: String) -> String? {
        if jsonString.contains("\"type\":\"Error\"") || jsonString.contains("\"type\": \"Error\"") {
            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                if let message = json["error"] as? String {
                    return message
                }
                if let description = json["description"] as? String {
                    return description
                }
            }
            return "Deepgram error"
        }
        return nil
    }

    /// Infers the dominant speaker via majority vote over word-level speakers.
    static func inferSpeakerId(from words: [DeepgramWord]?) -> Int? {
        guard let words else { return nil }
        var counts: [Int: Int] = [:]
        for word in words {
            guard let speaker = word.speaker else { continue }
            counts[speaker, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: - Error Introspection

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code))"
    }

    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Keep-Alive

    /// Deepgram expects a JSON keep-alive message
    private static let keepAliveMessage = "{\"type\": \"KeepAlive\"}"

    /// Sends the Deepgram keep-alive frame over the given socket.
    ///
    /// Cancellation errors are swallowed silently. Any other send error is
    /// reported to `onError` as a summary string. `onSuccess` fires only on
    /// a successful send: the dual-stream service uses it to mark a stream
    /// ready, while the legacy service keeps the default no-op.
    static func sendKeepAlive(
        over socket: URLSessionWebSocketTask?,
        onError: @escaping (String) -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        let message = URLSessionWebSocketTask.Message.string(keepAliveMessage)

        socket?.send(message) { error in
            if let error = error {
                if isCancellation(error) { return }
                onError(errorSummary(error))
                return
            }
            onSuccess()
        }
    }
}
