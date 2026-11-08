import Foundation

/// Decides whether a failed AI request attempt is retried, purely from typed
/// error cases. Backoff is exponential (1s, 2s, 4s) and no delay is ever
/// charged after the final attempt.
struct AIRetryPolicy {
    /// Longer server delays surface to the caller instead of retrying early or
    /// blocking an interactive request for minutes.
    static let maximumAutomaticDelay: TimeInterval = 60
    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case fail
    }

    func decision(for error: Error, attempt: Int, maxAttempts: Int) -> Decision {
        guard attempt < maxAttempts, isRetryable(error) else {
            return .fail
        }
        if case AIProviderError.responseError(let response) = error,
           let delay = response.retryAfter {
            guard delay.isFinite, delay >= 0, delay <= Self.maximumAutomaticDelay else { return .fail }
            return .retry(after: delay)
        }
        return .retry(after: min(Self.maximumAutomaticDelay, pow(2.0, Double(max(0, min(attempt - 1, 6))))))
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else {
            return false
        }
        switch providerError {
        case .rateLimited:
            return true
        case .httpError(let status, _, _):
            return status == 502 || status == 503 || status == 504
        case .responseError(let response):
            guard !response.isPermanentLimit, let status = response.statusCode else { return false }
            return status == 429 || status == 502 || status == 503 || status == 504
        case .timeout(let stage):
            return stage == .request || stage == .firstByte
        case .invalidAPIKey, .networkError, .parsingError, .unknown, .cancelled:
            return false
        }
    }
}
