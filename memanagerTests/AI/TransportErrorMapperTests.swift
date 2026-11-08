import XCTest
@testable import memanager

final class TransportErrorMapperTests: XCTestCase {
    func testProviderErrorsPassThroughUnchanged() {
        let mapped = TransportErrorMapper.map(AIProviderError.rateLimited)

        guard case AIProviderError.rateLimited = mapped else {
            return XCTFail("Expected rateLimited to pass through, got \(mapped)")
        }
    }

    func testCancellationErrorIsNotRewrappedAsNetworkError() {
        let mapped = TransportErrorMapper.map(CancellationError())

        XCTAssertTrue(mapped is CancellationError)
    }

    func testURLErrorCancelledBecomesCancellationError() {
        let mapped = TransportErrorMapper.map(URLError(.cancelled))

        XCTAssertTrue(mapped is CancellationError)
    }

    func testURLErrorTimedOutBecomesTypedRequestTimeout() {
        let mapped = TransportErrorMapper.map(URLError(.timedOut))

        guard case AIProviderError.timeout(let stage) = mapped else {
            return XCTFail("Expected typed timeout, got \(mapped)")
        }
        XCTAssertEqual(stage, .request)
    }

    func testOtherErrorsBecomeNetworkErrors() {
        let underlying = URLError(.notConnectedToInternet)

        let mapped = TransportErrorMapper.map(underlying)

        guard case AIProviderError.networkError = mapped else {
            return XCTFail("Expected networkError wrap, got \(mapped)")
        }
    }
}
