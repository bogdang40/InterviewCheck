import Foundation

/// Maps raw analyzer output primitives into the app wide `DeepgramTranscriptSegment`
/// DTO consumed by `TranscriptMerger` and `AudioCaptureService`.
///
/// Pure and stateless so the mapping contract is directly unit testable:
/// - Microphone segments carry no speaker id (the merger labels mic finals as "me").
/// - System segments carry a constant speaker id 0 so the merger maps the remote
///   party to the first numbered display speaker, matching the Deepgram contract.
struct AppleAnalyzerSegmentMapper {
    let source: AudioSource

    static let systemSpeakerID = 0

    func segment(
        text: String,
        confidence: Double?,
        startSeconds: Double,
        endSeconds: Double,
        isFinal: Bool
    ) -> DeepgramTranscriptSegment {
        let safeStart = sanitize(startSeconds)
        let safeEnd = max(safeStart, sanitize(endSeconds))
        return DeepgramTranscriptSegment(
            text: text,
            speaker: source == .systemAudio ? Self.systemSpeakerID : nil,
            startTime: safeStart,
            endTime: safeEnd,
            isFinal: isFinal,
            confidence: confidence.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil },
            words: []
        )
    }

    private func sanitize(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }
}
