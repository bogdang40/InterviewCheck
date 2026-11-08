import XCTest
@testable import memanager

final class AIRequestExecutorTests: XCTestCase {
    func testExecuteDataRequestReturnsBodyFor200() async throws {
        let body = Data("{\"ok\":true}".utf8)
        let transport = StubTransport(
            dataResult: .success((body, makeResponse(statusCode: 200)))
        )
        let executor = AIRequestExecutor(transport: transport)

        let result = try await executor.executeDataRequest(makeRequest(), profile: .solve)

        XCTAssertEqual(result, body)
    }

    func testExecuteDataRequestPreservesUnauthorizedResponse() async {
        let body = Data("{\"error\":\"unauthorized\"}".utf8)
        let transport = StubTransport(
            dataResult: .success((body, makeResponse(statusCode: 401)))
        )
        let executor = AIRequestExecutor(transport: transport)

        do {
            _ = try await executor.executeDataRequest(makeRequest(), profile: .solve)
            XCTFail("Expected authentication error")
        } catch let error as AIProviderError {
            if case .responseError(let response) = error {
                XCTAssertEqual(response.statusCode, 401)
                XCTAssertEqual(response.message, "unauthorized")
                return
            }
            XCTFail("Unexpected error: \(error)")
        } catch {
            XCTFail("Unexpected non-provider error: \(error)")
        }
    }

    func testExecuteStreamingTextRequestBatchesAndParses() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"hello "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"world\n"}}]}"#,
            "data: [DONE]"
        ]
        let transport = StubTransport(
            streamResult: .success((makeResponse(statusCode: 200), makeLineStream(lines)))
        )
        let executor = AIRequestExecutor(transport: transport)

        var chunks: [String] = []
        let fullText = try await executor.executeStreamingTextRequest(
            makeRequest(),
            profile: .quickAssist,
            chunkPolicy: .batched(interval: 10, flushOnNewline: true),
            lineParser: parseOpenAIChunk,
            onChunk: { chunks.append($0) }
        )

        XCTAssertEqual(fullText, "hello world\n")
        XCTAssertEqual(chunks, ["hello ", "world\n"])
    }

    func testWithRetryRetriesRateLimitedThenSucceeds() async throws {
        var attempts = 0
        let value: Int = try await AINetworkSession.withRetry(attempts: 2) {
            attempts += 1
            if attempts < 2 {
                throw AIProviderError.rateLimited
            }
            return 7
        }

        XCTAssertEqual(value, 7)
        XCTAssertEqual(attempts, 2)
    }
}

private extension AIRequestExecutorTests {
    func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://example.com")!)
    }

    func makeResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func makeLineStream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }

    func parseOpenAIChunk(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }
}

private final class StubTransport: NetworkTransport {
    private let dataResult: Result<(Data, URLResponse), Error>
    private let streamResult: Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error>

    init(
        dataResult: Result<(Data, URLResponse), Error> = .success((
            Data(),
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )),
        streamResult: Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error> = .success((
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        ))
    ) {
        self.dataResult = dataResult
        self.streamResult = streamResult
    }

    func data(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (Data, URLResponse) {
        try dataResult.get()
    }

    func streamLines(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        try streamResult.get()
    }
}
