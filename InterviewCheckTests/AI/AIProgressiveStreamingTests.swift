import XCTest
@testable import InterviewCheck

final class AIProgressiveStreamingTests: XCTestCase {
    func testExecutorPublishesTextWhileResponseIsStillOpen() async throws {
        let transport = OpenStreamTransport()
        let first = expectation(description: "first token before completion")
        let second = expectation(description: "buffered token without another network event")
        let task = Task {
            try await AIRequestExecutor(transport: transport).executeStreamingTextRequest(
                URLRequest(url: URL(string: "https://provider.invalid/stream")!),
                profile: .quickAssist,
                chunkPolicy: .batched(interval: 0.01, flushOnNewline: false),
                lineParser: { String(data: $0, encoding: .utf8) },
                onChunk: { text in
                    if text == "Hello" { first.fulfill() }
                    if text == " world" { second.fulfill() }
                }
            )
        }
        transport.continuation.yield("data: Hello")
        await fulfillment(of: [first], timeout: 1)
        transport.continuation.yield("data:  world")
        await fulfillment(of: [second], timeout: 1)
        transport.continuation.yield("data: [DONE]")
        transport.continuation.finish()
        let answer = try await task.value
        XCTAssertEqual(answer, "Hello world")
    }
}

private final class OpenStreamTransport: NetworkTransport {
    let stream: AsyncThrowingStream<String, Error>
    let continuation: AsyncThrowingStream<String, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func data(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (Data, URLResponse) {
        throw AIProviderError.unknown("Expected a streaming request")
    }

    func streamLines(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, stream)
    }
}
