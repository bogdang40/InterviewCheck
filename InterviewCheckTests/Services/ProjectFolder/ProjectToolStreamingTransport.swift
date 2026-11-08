import Foundation
@testable import InterviewCheck

/// No URLSession is used. Tests choose exactly when the next SSE line arrives.
final class ProjectToolStreamingTransport: NetworkTransport {
    private(set) var requests: [URLRequest] = []
    private var pending: [AsyncThrowingStream<String, Error>] = []

    func enqueue() -> AsyncThrowingStream<String, Error>.Continuation {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pending.append(pair.stream)
        return pair.continuation
    }

    func data(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (Data, URLResponse) {
        throw StubError.nonStreamingRequest
    }

    func streamLines(for request: URLRequest, profile: AINetworkSession.SessionProfile) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        guard !pending.isEmpty else { throw StubError.unexpectedRequest }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, pending.removeFirst())
    }

    enum StubError: Error { case nonStreamingRequest, unexpectedRequest }
}

extension AsyncThrowingStream<String, Error>.Continuation {
    func event(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        yield("data: " + String(decoding: data, as: UTF8.self))
    }
}
