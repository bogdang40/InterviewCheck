import Foundation

/// Owns the two background rhythms of access verification: the short burst
/// of polling after a checkout opens in the browser, and the long interval
/// re-verification that lets revoked subscriptions lapse without a relaunch.
/// Keeps task lifecycle out of AccessController.
@MainActor
final class AccessVerificationScheduler {
    private var checkoutTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    /// Polls `verify` until it reports success or the attempts run out.
    func startCheckoutPolling(
        interval: TimeInterval = 4,
        attempts: Int = 45,
        verify: @escaping @MainActor () async -> Bool,
        onFinished: @escaping @MainActor () -> Void
    ) {
        stopCheckoutPolling()
        checkoutTask = Task { [weak self] in
            // A cancelled poll was replaced (or stopped) by its owner, who
            // already decided what the flag should be; only a poll that
            // ran to its own end reports back.
            defer { if !Task.isCancelled { onFinished() } }
            for _ in 0..<attempts {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard self != nil, !Task.isCancelled else { return }
                if await verify() { break }
            }
        }
    }

    func stopCheckoutPolling() {
        checkoutTask?.cancel()
        checkoutTask = nil
    }

    /// `verify` returns false to end the loop (for example when its owner is gone).
    func startPeriodic(every interval: TimeInterval, verify: @escaping @MainActor () async -> Bool) {
        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard await verify() else { return }
            }
        }
    }
}
