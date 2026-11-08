import Foundation

/// Integrates the prior frame's motion rate so pause, visibility, and speed
/// changes preserve the current phase instead of jumping to wall-clock time.
struct GlassBorderAnimationClock {
    private(set) var elapsed: TimeInterval = 0
    private var previous: TimeInterval?

    mutating func advance(to timestamp: TimeInterval, isRunning: Bool, speed: Double) -> Float {
        guard timestamp.isFinite else { return Float(elapsed) }
        if let previous {
            guard timestamp >= previous else { return Float(elapsed) }
            if isRunning && speed.isFinite {
                elapsed += (timestamp - previous) * max(0, speed)
            }
        }
        previous = timestamp
        return Float(elapsed)
    }
}
