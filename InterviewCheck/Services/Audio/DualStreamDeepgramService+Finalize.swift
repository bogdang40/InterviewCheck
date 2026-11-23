import Foundation

extension DualStreamDeepgramService {
    /// Deepgram's control message that turns held, still interim audio into
    /// final results (developers.deepgram.com/docs/finalize).
    static let finalizeMessage = #"{"type":"Finalize"}"#

    /// Asks each open stream to finalize, then calls `completion` on the main
    /// queue once every stream answered (a result with `from_finalize`), its
    /// socket ended, or `timeout` passed, since Deepgram may not answer when
    /// it held no audio. Words in those answers are delivered first.
    /// Call on the main queue; with no open stream it completes at once.
    func finalize(timeout: TimeInterval = 2, completion: @escaping () -> Void) {
        finalizeWaiter?.expire()
        let sockets: [(AudioSource, URLSessionWebSocketTask)] = stateLock.withLock {
            [(.microphone, micWebSocket), (.systemAudio, systemWebSocket)].compactMap { source, socket in
                socket.map { (source, $0) }
            }
        }
        guard !sockets.isEmpty else {
            completion()
            return
        }
        let waiter = FinalizeWaiter(sources: Set(sockets.map(\.0)), completion: completion)
        finalizeWaiter = waiter
        sendLock.lock()
        for (source, socket) in sockets {
            transmit(socket, .string(Self.finalizeMessage)) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.resolveFinalize(source) }
            }
        }
        sendLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak waiter] in waiter?.expire() }
    }

    /// A stream answered Finalize or ended; main queue only.
    func resolveFinalize(_ source: AudioSource) {
        guard let waiter = finalizeWaiter else { return }
        waiter.resolve(source)
        if waiter.isFinished { finalizeWaiter = nil }
    }
}
