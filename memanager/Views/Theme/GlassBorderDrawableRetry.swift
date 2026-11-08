import Foundation

/// A static frame gets three delayed retries after transient drawable loss.
/// Exhaustion leaves it idle until a new configuration or visibility event.
struct GlassBorderDrawableRetry {
    private var attempts = 0

    mutating func nextDelay() -> TimeInterval? {
        guard attempts < 3 else { return nil }
        let delay = 0.016 * Double(1 << attempts)
        attempts += 1
        return delay
    }

    mutating func reset() { attempts = 0 }
}
