import Foundation

/// Delivers the first token immediately, then batches bursts with a real
/// deadline. A quiet connection cannot strand the final buffered token.
final class AIStreamTextDelivery {
    private let lock = NSLock()
    private let policy: AIStreamChunkPolicy
    private let onChunk: (String) -> Void
    private var buffer = ""
    private var deliveredFirst = false
    private var finished = false
    private var pendingFlush: DispatchWorkItem?
    private var generation = 0

    init(policy: AIStreamChunkPolicy, onChunk: @escaping (String) -> Void) {
        self.policy = policy
        self.onChunk = onChunk
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.withLock {
            guard !finished else { return }
            buffer += text
            switch policy {
            case .immediate:
                flushLocked()
            case .batched(let interval, let flushOnNewline):
                if !deliveredFirst || interval <= 0 || (flushOnNewline && text.contains("\n")) {
                    flushLocked()
                } else if pendingFlush == nil {
                    let expected = generation
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.withLock {
                            guard !self.finished, self.generation == expected else { return }
                            self.flushLocked()
                        }
                    }
                    pendingFlush = work
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: work)
                }
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            flushLocked()
        }
    }

    private func flushLocked() {
        generation += 1
        pendingFlush?.cancel()
        pendingFlush = nil
        guard !buffer.isEmpty else { return }
        let text = buffer
        buffer = ""
        deliveredFirst = true
        // Serialize callbacks with append/finish so completion cannot overtake
        // a timer callback. Consumers must not reenter this delivery object.
        onChunk(text)
    }
}
