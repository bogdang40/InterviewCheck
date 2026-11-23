import Foundation

/// One wait for Deepgram to answer Finalize on each open stream. Used on the
/// main queue only; `completion` runs once, when every stream answered,
/// closed, or the time ran out.
final class FinalizeWaiter {
    private var pending: Set<AudioSource>
    private var completion: (() -> Void)?

    init(sources: Set<AudioSource>, completion: @escaping () -> Void) {
        self.pending = sources
        self.completion = completion
    }

    var isFinished: Bool { completion == nil }

    func resolve(_ source: AudioSource) {
        pending.remove(source)
        if pending.isEmpty { expire() }
    }

    func expire() {
        let done = completion
        completion = nil
        done?()
    }
}
