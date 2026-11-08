import Foundation

/// Confined to one serial render queue. Committed targets survive configuration
/// and visibility changes because an older drawable may still await display.
final class GlassBorderPresentationTimeline {
    private weak var layer: AnyObject?
    private var lastCommittedTime: TimeInterval?

    func target(for layer: AnyObject, prediction: GlassBorderFramePrediction?, now: TimeInterval) -> TimeInterval {
        let candidate = prediction?.time(at: now) ?? now
        guard self.layer === layer, let previous = lastCommittedTime else { return candidate }
        // Equal targets can strand the newer static drawable. Advance by one
        // representable step rather than adding a display interval per edit.
        return candidate > previous ? candidate : previous.nextUp
    }

    /// Called only after commit; cancelled or rejected work cannot delay an edit.
    func recordCommit(_ timestamp: TimeInterval, for layer: AnyObject) {
        guard timestamp.isFinite else { return }
        lastCommittedTime = self.layer === layer ? max(lastCommittedTime ?? timestamp, timestamp) : timestamp
        self.layer = layer
    }
}
