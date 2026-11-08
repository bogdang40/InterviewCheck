import XCTest
@testable import InterviewCheck

final class AIRetryPolicyTests: XCTestCase {
    private let policy = AIRetryPolicy()

    func testRateLimitedRetriesWithExponentialBackoff() {
        XCTAssertEqual(
            policy.decision(for: AIProviderError.rateLimited, attempt: 1, maxAttempts: 3),
            .retry(after: 1)
        )
        XCTAssertEqual(
            policy.decision(for: AIProviderError.rateLimited, attempt: 2, maxAttempts: 3),
            .retry(after: 2)
        )
    }

    func testNoRetryDecisionOnFinalAttempt() {
        XCTAssertEqual(
            policy.decision(for: AIProviderError.rateLimited, attempt: 3, maxAttempts: 3),
            .fail
        )
    }

    func testServerErrorsRetryButClientErrorsFail() {
        for status in [502, 503, 504] {
            XCTAssertEqual(
                policy.decision(
                    for: AIProviderError.httpError(status: status, apiCode: nil, message: "HTTP \(status)"),
                    attempt: 1,
                    maxAttempts: 3
                ),
                .retry(after: 1),
                "HTTP \(status) should retry"
            )
        }
        XCTAssertEqual(
            policy.decision(
                for: AIProviderError.httpError(status: 400, apiCode: nil, message: "bad request"),
                attempt: 1,
                maxAttempts: 3
            ),
            .fail
        )
    }

    func testRequestAndFirstByteTimeoutsRetryLaterStagesFail() {
        XCTAssertEqual(
            policy.decision(for: AIProviderError.timeout(stage: .request), attempt: 1, maxAttempts: 3),
            .retry(after: 1)
        )
        XCTAssertEqual(
            policy.decision(for: AIProviderError.timeout(stage: .firstByte), attempt: 1, maxAttempts: 3),
            .retry(after: 1)
        )
        XCTAssertEqual(
            policy.decision(for: AIProviderError.timeout(stage: .interChunk), attempt: 1, maxAttempts: 3),
            .fail
        )
        XCTAssertEqual(
            policy.decision(for: AIProviderError.timeout(stage: .total), attempt: 1, maxAttempts: 3),
            .fail
        )
    }

    func testProseBearingNetworkErrorsNoLongerRetry() {
        let proseError = AIProviderError.networkError("connection timeout while contacting 503 backend")

        XCTAssertEqual(
            policy.decision(for: proseError, attempt: 1, maxAttempts: 3),
            .fail
        )
    }

    func testCancellationAndUnknownErrorsFail() {
        XCTAssertEqual(
            policy.decision(for: AIProviderError.cancelled, attempt: 1, maxAttempts: 3),
            .fail
        )
        XCTAssertEqual(
            policy.decision(for: CancellationError(), attempt: 1, maxAttempts: 3),
            .fail
        )
    }

    func testWithRetrySleepsOnlyBetweenAttempts() async throws {
        var recordedDelays: [TimeInterval] = []
        var attempts = 0

        await XCTAssertThrowsErrorAsync(
            try await AINetworkSession.withRetry(
                attempts: 3,
                sleep: { recordedDelays.append($0) }
            ) {
                attempts += 1
                throw AIProviderError.rateLimited
            }
        )

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(recordedDelays, [1, 2], "No backoff sleep after the final attempt")
    }

    func testWithRetryRecoversAfterTransientFailures() async throws {
        var recordedDelays: [TimeInterval] = []
        var attempts = 0

        let result = try await AINetworkSession.withRetry(
            attempts: 3,
            sleep: { recordedDelays.append($0) }
        ) { () -> String in
            attempts += 1
            if attempts < 3 {
                throw AIProviderError.httpError(status: 503, apiCode: nil, message: "HTTP 503")
            }
            return "recovered"
        }

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(recordedDelays, [1, 2])
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
