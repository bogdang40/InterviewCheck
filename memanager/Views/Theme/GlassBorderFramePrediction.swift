import Foundation

/// CADisplayLink predicts the next display time. Reject stale predictions and
/// bound future targets to one observed interval, never beyond the 30 Hz budget.
struct GlassBorderFramePrediction {
    let timestamp: TimeInterval
    let frameInterval: TimeInterval

    func time(at now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, timestamp.isFinite, frameInterval.isFinite,
              frameInterval > 0, timestamp > now,
              timestamp - now <= min(frameInterval, 1.0 / 30) else { return nil }
        return timestamp
    }
}
