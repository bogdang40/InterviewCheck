import XCTest
@testable import InterviewCheck

final class AIHTTPFailureTests: XCTestCase {
    func testPermanentQuotaCodesAndTypeNeverRetry() throws {
        let codes = ["insufficient_quota", "credit_balance_exhausted",
                     "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                     "organization_usage_limit_exceeded", "billing_hard_limit_reached"]
        for code in codes {
            let error = try failure(code: code, type: "rate_limit_error", retryAfter: "2")
            XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .fail, code)
        }
        let error = try failure(code: "future_billing_code", type: "insufficient_quota")
        XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .fail)
    }

    func testTransientRateLimitsHonorRetryAfterWithoutProseMatching() throws {
        for code in ["slow_down", "rate_limit_exceeded"] {
            let error = try failure(code: code, type: "rate_limit_error", retryAfter: "1.75")
            XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 2, maxAttempts: 3), .retry(after: 1.75))
            XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 3, maxAttempts: 3), .fail)
        }
        let error = try failure(code: "rate_limit_exceeded", message: "The phrase insufficient_quota is only prose")
        XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .retry(after: 1))
    }

    func testRetryAfterDatesMillisecondsAndInvalidValues() throws {
        let now = Date(timeIntervalSince1970: 784_111_770) // 1994-11-06 08:49:30 UTC
        let response = makeHTTPResponse(status: 429, headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"])
        let parsed = try details(APIErrorBodyParser.httpError(response: response, body: Data(), now: now))
        XCTAssertEqual(parsed.retryAfter, 7)
        let past = try details(APIErrorBodyParser.httpError(response: response, body: Data(), now: now.addingTimeInterval(10)))
        XCTAssertEqual(past.retryAfter, 0)
        let milliseconds = makeHTTPResponse(status: 429, headers: ["retry-after-ms": "1250", "Retry-After": "9"])
        XCTAssertEqual(try details(APIErrorBodyParser.httpError(response: milliseconds, body: Data())).retryAfter, 1.25)
        for invalid in ["-2", "nan", "Infinity", "not a date"] {
            XCTAssertNil(try details(failure(retryAfter: invalid)).retryAfter)
        }
    }

    func testLongServerDelayDoesNotRetryBeforeItsDeadline() throws {
        let error = try failure(retryAfter: "120")
        XCTAssertEqual(try details(error).retryAfter, 120)
        XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .fail)
    }

    func testMetadataStaysDistinctAndCredentialEchoIsRedacted() throws {
        let body = Data(#"{"error":{"code":"invalid_api_key","type":"authentication_error","param":"api_key","message":"Rejected sk-proj-privateCredential; Bearer privateCredential"}}"#.utf8)
        let error = APIErrorBodyParser.httpError(response: makeHTTPResponse(status: 401), body: body)
        let result = try details(error)
        XCTAssertEqual(result.statusCode, 401)
        XCTAssertEqual(result.code, "invalid_api_key")
        XCTAssertEqual(result.type, "authentication_error")
        XCTAssertEqual(result.parameter, "api_key")
        XCTAssertFalse(result.message.contains("privateCredential"))
        XCTAssertTrue(error.localizedDescription.contains("authentication") || error.localizedDescription.contains("invalid_api_key"))
        XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .fail)
        XCTAssertLessThanOrEqual(APIErrorBodyParser.parse(Data(String(repeating: "x", count: 50_000).utf8)).message.count, 2_048)
    }

    func testDataTransportPreservesQuotaBodyWithoutRetry() async throws {
        let fixture = try makeTransport(statuses: [429], body: quotaBody)
        defer { fixture.session.invalidateAndCancel() }
        do {
            _ = try await fixture.transport.data(for: makeHTTPRequest(), profile: .quickAssist)
            XCTFail("Expected quota error")
        } catch {
            XCTAssertEqual(try details(error).code, "insufficient_quota")
            XCTAssertEqual(try details(error).message, "Billing action required")
        }
        XCTAssertEqual(HTTPFailureURLProtocol.requestCount, 1)
        XCTAssertTrue(fixture.delays.values.isEmpty)
    }

    func testStreamingTransportPreservesQuotaBodyWithoutRetry() async throws {
        let fixture = try makeTransport(statuses: [429], body: quotaBody)
        defer { fixture.session.invalidateAndCancel() }
        do {
            _ = try await fixture.transport.streamLines(for: makeHTTPRequest(), profile: .quickAssist)
            XCTFail("Expected quota error before opening stream")
        } catch {
            XCTAssertEqual(try details(error).code, "insufficient_quota")
            XCTAssertEqual(try details(error).retryAfter, 0.25)
        }
        XCTAssertEqual(HTTPFailureURLProtocol.requestCount, 1)
        XCTAssertTrue(fixture.delays.values.isEmpty)
    }

    func testDataAndStreamingTransportRetryTransientOpeningOnly() async throws {
        for streaming in [false, true] {
            let fixture = try makeTransport(statuses: [429, 200], body: Data(#"{"error":{"code":"slow_down","type":"rate_limit_error","message":"Wait"}}"#.utf8))
            defer { fixture.session.invalidateAndCancel() }
            if streaming {
                let (response, lines) = try await fixture.transport.streamLines(for: makeHTTPRequest(), profile: .quickAssist)
                XCTAssertEqual(response.statusCode, 200)
                for try await _ in lines { }
            } else {
                let (_, response) = try await fixture.transport.data(for: makeHTTPRequest(), profile: .quickAssist)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            }
            XCTAssertEqual(HTTPFailureURLProtocol.requestCount, 2)
            XCTAssertEqual(fixture.delays.values, [0.25])
        }
    }

    private var quotaBody: Data {
        Data(#"{"error":{"code":"insufficient_quota","type":"insufficient_quota","message":"Billing action required"}}"#.utf8)
    }

    private func makeTransport(statuses: [Int], body: Data) throws -> (transport: URLSessionNetworkTransport, session: URLSession, delays: RecordedDelays) {
        HTTPFailureURLProtocol.configure(statuses: statuses, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPFailureURLProtocol.self]
        let session = URLSession(configuration: config)
        let delays = RecordedDelays()
        return (URLSessionNetworkTransport(session: session, retrySleep: { delays.append($0) }), session, delays)
    }

    private func failure(code: String = "rate_limit_exceeded", type: String = "rate_limit_error", message: String = "Provider detail", retryAfter: String? = nil) throws -> AIProviderError {
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "type": type, "message": message]])
        let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
        return APIErrorBodyParser.httpError(response: makeHTTPResponse(status: 429, headers: headers), body: body)
    }

    private func details(_ error: Error) throws -> APIResponseError {
        guard case AIProviderError.responseError(let response) = error else {
            throw NSError(domain: "Expected responseError, got \(error)", code: 1)
        }
        return response
    }
}

private final class RecordedDelays {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { storage } }
    func append(_ delay: TimeInterval) { lock.withLock { storage.append(delay) } }
}

/// Fully intercepted requests. No app initialization, credentials or sockets.
private final class HTTPFailureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statuses: [Int] = []
    private static var body = Data()
    private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func configure(statuses: [Int], body: Data) {
        lock.withLock { self.statuses = statuses; self.body = body; count = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock {
            let status = Self.statuses[min(Self.count, Self.statuses.count - 1)]
            Self.count += 1
            return (status, Self.body)
        }
        client?.urlProtocol(self, didReceive: makeHTTPResponse(status: status, headers: ["Retry-After": "0.25"]), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private func makeHTTPRequest() -> URLRequest { URLRequest(url: URL(string: "https://provider.invalid/fixture")!) }
private func makeHTTPResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: makeHTTPRequest().url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}
