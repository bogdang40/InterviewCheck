import XCTest
@testable import InterviewCheck

final class AIStreamingFailureTests: XCTestCase {
    func testBufferedTextIsFlushedBeforeTransportFailureWithoutRetry() async {
        let transport = FailureStreamTransport(lines: [textLine], terminalError: AIProviderError.timeout(stage: .interChunk))
        var chunks: [String] = []
        do {
            _ = try await execute(transport, chunks: { chunks.append($0) })
            XCTFail("Expected stream timeout")
        } catch {
            guard case AIProviderError.timeout(stage: .interChunk) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(chunks, ["partial answer"])
        XCTAssertEqual(transport.calls, 1)
    }

    func testTerminalSSEErrorsPreserveProviderMessageAndPartialText() async throws {
        let frames = [
            #"{"error":{"code":"rate_limit_exceeded","type":"rate_limit_error","message":"Slow down"}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            #"{"type":"error","code":"server_error","message":"Processing failed"}"#,
            #"{"type":"response.failed","response":{"error":{"code":"server_error","message":"Generation failed"}}}"#
        ]
        let messages = ["Slow down", "Overloaded", "Processing failed", "Generation failed"]
        for (frame, message) in zip(frames, messages) {
            let transport = FailureStreamTransport(lines: [textLine, "data: \(frame)"])
            var chunks: [String] = []
            do {
                _ = try await execute(transport, chunks: { chunks.append($0) })
                XCTFail("Expected SSE error")
            } catch {
                let detail = try responseError(error)
                XCTAssertEqual(detail.message, message)
                XCTAssertNil(detail.statusCode)
                XCTAssertEqual(AIRetryPolicy().decision(for: error, attempt: 1, maxAttempts: 3), .fail)
            }
            XCTAssertEqual(chunks, ["partial answer"])
            XCTAssertEqual(transport.calls, 1)
        }
    }

    func testIncompleteResponseIsAnErrorAfterPartialText() async throws {
        let frame = #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        let transport = FailureStreamTransport(lines: [textLine, frame])
        var chunks: [String] = []
        do {
            _ = try await execute(transport, chunks: { chunks.append($0) })
            XCTFail("Expected incomplete response")
        } catch {
            XCTAssertEqual(try responseError(error).code, "max_output_tokens")
        }
        XCTAssertEqual(chunks, ["partial answer"])
    }

    func testDoneStopsBeforeSubsequentFrames() async throws {
        let transport = FailureStreamTransport(lines: [textLine, "data: [DONE]", #"data: {"error":{"message":"must not read"}}"#])
        var chunks: [String] = []
        let result = try await execute(transport, chunks: { chunks.append($0) })
        XCTAssertEqual(result, "partial answer")
        XCTAssertEqual(chunks, [result])
    }

    func testHTTPErrorFromCustomTransportRetainsBodyAndHeaders() async throws {
        let transport = FailureStreamTransport(
            status: 429,
            lines: ["{", #""error":{"code":"credit_balance_exhausted","type":"insufficient_quota","message":"Add credits"}"#, "}"],
            headers: ["Retry-After": "30"]
        )
        do {
            _ = try await execute(transport, chunks: { _ in XCTFail("Error body is not answer text") })
            XCTFail("Expected HTTP error")
        } catch {
            let detail = try responseError(error)
            XCTAssertEqual(detail.statusCode, 429)
            XCTAssertEqual(detail.code, "credit_balance_exhausted")
            XCTAssertEqual(detail.message, "Add credits")
            XCTAssertEqual(detail.retryAfter, 30)
        }
    }

    func testKnownHTTPStatusSurvivesInterruptedErrorBody() async throws {
        let transport = FailureStreamTransport(status: 503, lines: ["upstream unavailable"], terminalError: URLError(.networkConnectionLost))
        do {
            _ = try await execute(transport, chunks: { _ in })
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(try responseError(error).statusCode, 503)
            XCTAssertEqual(try responseError(error).message, "upstream unavailable")
        }
    }

    func testOrdinaryToolOutputContainingNestedErrorIsNotFailure() {
        let payload = Data(#"{"type":"response.output_item.done","item":{"output":{"error":{"message":"Tool result"}}}}"#.utf8)
        XCTAssertNil(APIErrorBodyParser.streamError(from: payload))
    }

    private var textLine: String { #"data: {"text":"partial answer"}"# }
    private func execute(_ transport: FailureStreamTransport, chunks: @escaping (String) -> Void) async throws -> String {
        try await AIRequestExecutor(transport: transport).executeStreamingTextRequest(
            URLRequest(url: URL(string: "https://provider.invalid/fixture")!),
            profile: .quickAssist, chunkPolicy: .batched(interval: 100, flushOnNewline: false),
            lineParser: { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["text"] as? String },
            onChunk: chunks
        )
    }
    private func responseError(_ error: Error) throws -> APIResponseError {
        guard case AIProviderError.responseError(let detail) = error else {
            throw NSError(domain: "Expected responseError, got \(error)", code: 1)
        }
        return detail
    }
}

private final class FailureStreamTransport: NetworkTransport {
    let status: Int
    let lines: [String]
    let terminalError: Error?
    let headers: [String: String]
    var calls = 0
    init(status: Int = 200, lines: [String], terminalError: Error? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.lines = lines
        self.terminalError = terminalError
        self.headers = headers
    }
    func data(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (Data, URLResponse) {
        throw AIProviderError.unknown("Unexpected data request")
    }
    func streamLines(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        calls += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let stream = AsyncThrowingStream<String, Error> { continuation in
            lines.forEach { continuation.yield($0) }
            if let terminalError { continuation.finish(throwing: terminalError) } else { continuation.finish() }
        }
        return (response, stream)
    }
}
