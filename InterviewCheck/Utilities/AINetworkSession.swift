import Foundation

/// URLSession configured for AI API calls with streaming-safe timeouts.
///
/// URLSession's request timeout resets whenever data arrives, so it acts as a
/// coarse inter-chunk guard. The fine grained, typed staged timeouts (first
/// byte, inter chunk, total) come from StreamWatchdog driven by
/// StreamTimeoutPolicy; the URLSession values sit slightly above the watchdog
/// budgets so the watchdog fires first with a typed error.
final class AINetworkSession {
    enum SessionProfile {
        case solve
        case quickAssist
        case mlGuide
        case debrief
    }

    /// Solve and debrief allowances (long reasoning tolerated).
    static let solveRequestTimeout: TimeInterval = 120
    static let solveResourceTimeout: TimeInterval = 30 * 60

    /// Quick Assist and ML Guide allowances (interactive surfaces).
    static let quickRequestTimeout: TimeInterval = 90
    static let quickResourceTimeout: TimeInterval = 15 * 60

    /// Shared session for solve and debrief requests
    static let shared: URLSession = {
        let config = TestRuntime.isRunningUnitTests ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = solveRequestTimeout
        config.timeoutIntervalForResource = solveResourceTimeout
        return URLSession(configuration: config)
    }()

    /// Quick Assist session -- tighter interactive budgets
    static let quickSession: URLSession = {
        let config = TestRuntime.isRunningUnitTests ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = quickRequestTimeout
        config.timeoutIntervalForResource = quickResourceTimeout
        return URLSession(configuration: config)
    }()

    /// ML Guide session -- tighter interactive budgets
    static let mlGuideSession: URLSession = {
        let config = TestRuntime.isRunningUnitTests ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = quickRequestTimeout
        config.timeoutIntervalForResource = quickResourceTimeout
        return URLSession(configuration: config)
    }()

    private init() {}

    static func session(for profile: SessionProfile) -> URLSession {
        switch profile {
        case .solve:
            return shared
        case .quickAssist:
            return quickSession
        case .mlGuide:
            return mlGuideSession
        case .debrief:
            return shared
        }
    }

    // MARK: - Retry Logic

    /// Maximum number of retry attempts
    static let maxRetryAttempts = 3

    /// Perform an async operation with retry decisions delegated to
    /// AIRetryPolicy (typed error matching, exponential backoff, and no
    /// backoff sleep after the final attempt).
    /// - Parameters:
    ///   - attempts: Maximum number of attempts (default: 3)
    ///   - policy: Decides retry versus fail per typed error
    ///   - sleep: Injectable backoff sleeper for tests
    ///   - operation: The async operation to perform
    static func withRetry<T>(
        attempts: Int = maxRetryAttempts,
        policy: AIRetryPolicy = AIRetryPolicy(),
        sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                switch policy.decision(for: error, attempt: attempt, maxAttempts: attempts) {
                case .retry(let delay):
                    // Provider messages can echo request content. Keep them out
                    // of retry logs; the typed error is still returned to callers.
                    NSLog("[AINetworkSession] Retry \(attempt)/\(attempts) after \(delay)s")
                    try await sleep(delay)
                    attempt += 1
                case .fail:
                    throw error
                }
            }
        }
    }
}
