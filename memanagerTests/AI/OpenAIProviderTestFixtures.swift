import XCTest
@testable import memanager

extension OpenAIProviderTests {
    func makeQuickAssistContext(modelTier: QuickAssistModelTier = .fast) -> QuickAssistContext {
        QuickAssistContext(
            transcript: "Me: solve this",
            screenshots: [],
            question: "Question?",
            extraContext: "",
            realtimePrompt: "",
            modelTier: modelTier
        )
    }

    func decodeJSONBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return value
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

final class RecordingTransport: NetworkTransport {
    private var dataResults: [Result<(Data, URLResponse), Error>]
    private var streamResults: [Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error>]

    private(set) var dataRequests: [URLRequest] = []
    private(set) var streamRequests: [URLRequest] = []

    init(
        dataResults: [Result<(Data, URLResponse), Error>] = [],
        streamResults: [Result<(HTTPURLResponse, AsyncThrowingStream<String, Error>), Error>] = []
    ) {
        self.dataResults = dataResults
        self.streamResults = streamResults
    }

    func data(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (Data, URLResponse) {
        dataRequests.append(request)
        guard !dataResults.isEmpty else {
            throw RecordingTransportError.noQueuedDataResult
        }
        return try dataResults.removeFirst().get()
    }

    func streamLines(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        streamRequests.append(request)
        guard !streamResults.isEmpty else {
            throw RecordingTransportError.noQueuedStreamResult
        }
        return try streamResults.removeFirst().get()
    }
}

private enum RecordingTransportError: Error {
    case noQueuedDataResult
    case noQueuedStreamResult
}
