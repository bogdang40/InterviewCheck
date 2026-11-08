import XCTest
@testable import memanager

/// Regression tests for the realistic OpenAI Responses SSE sequence: the API
/// emits incremental `response.output_text.delta` events and then a
/// `response.output_text.done` event carrying the full accumulated text for
/// the same item. The done event must not re-emit text that already streamed
/// as deltas, while remaining the fallback for streams that never emit deltas.
final class OpenAIResponsesStreamSequenceTests: XCTestCase {
    func testDeltaThenDoneSequenceEmitsTextOnce() async throws {
        let lines = [
            #"data: {"type":"response.created"}"#,
            #"data: {"type":"response.output_text.delta","delta":"hello ","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.output_text.delta","delta":"world","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.output_text.done","text":"hello world","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let chunks = try await streamChunks(lines: lines)

        XCTAssertEqual(chunks.joined(), "hello world")
    }

    func testDoneOnlyStreamWithItemIDsStillYieldsText() async throws {
        let lines = [
            #"data: {"type":"response.output_text.done","text":"hello world","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let chunks = try await streamChunks(lines: lines)

        XCTAssertEqual(chunks.joined(), "hello world")
    }

    func testMultiItemStreamEmitsEachItemTextExactlyOnce() async throws {
        let lines = [
            #"data: {"type":"response.output_text.delta","delta":"alpha ","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.output_text.done","text":"alpha ","item_id":"msg_1","content_index":0}"#,
            #"data: {"type":"response.output_text.done","text":"beta","item_id":"msg_2","content_index":0}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let chunks = try await streamChunks(lines: lines)

        XCTAssertEqual(chunks.joined(), "alpha beta")
    }

    func testDoneWithoutItemIDIsSuppressedAfterAnyDelta() async throws {
        let lines = [
            #"data: {"type":"response.output_text.delta","delta":"hello world"}"#,
            #"data: {"type":"response.output_text.done","text":"hello world"}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let chunks = try await streamChunks(lines: lines)

        XCTAssertEqual(chunks.joined(), "hello world")
    }
}

private extension OpenAIResponsesStreamSequenceTests {
    func streamChunks(lines: [String]) async throws -> [String] {
        let transport = SequenceRecordingTransport(
            streamResults: [
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(lines)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            transport: transport
        )

        var chunks: [String] = []
        try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { chunk in
            chunks.append(chunk)
        }
        return chunks
    }

    func makeQuickAssistContext() -> QuickAssistContext {
        QuickAssistContext(
            transcript: "Me: solve this",
            screenshots: [],
            question: "Question?",
            extraContext: "",
            realtimePrompt: "",
            modelTier: .fast
        )
    }

    func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
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
}

private final class SequenceRecordingTransport: NetworkTransport {
    private var streamResults: [Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error>]

    init(streamResults: [Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error>]) {
        self.streamResults = streamResults
    }

    func data(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (Data, URLResponse) {
        throw SequenceTransportError.unexpectedDataRequest
    }

    func streamLines(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        guard !streamResults.isEmpty else {
            throw SequenceTransportError.noQueuedStreamResult
        }
        return try streamResults.removeFirst().get()
    }
}

private enum SequenceTransportError: Error {
    case unexpectedDataRequest
    case noQueuedStreamResult
}
