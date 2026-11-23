import Foundation

extension AudioCaptureService {
    /// Lets Deepgram turn the last, still interim words into final ones
    /// before the interview stops capture; `completion` runs on the main
    /// queue within about `timeout` seconds, at once when nothing streams.
    @MainActor
    func finishTranscription(timeout: TimeInterval = 2, completion: @escaping () -> Void) {
        guard activeTranscriptionMode.usesSourceBasedDeepgram, let service = dualStreamService else {
            completion()
            return
        }
        service.finalize(timeout: timeout, completion: completion)
    }
}
