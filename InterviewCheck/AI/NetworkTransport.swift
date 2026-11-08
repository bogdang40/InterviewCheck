import Foundation

protocol NetworkTransport {
    func data(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (Data, URLResponse)

    func streamLines(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

final class URLSessionNetworkTransport: NetworkTransport {
    private let injectedSession: URLSession?
    private let retrySleep: (TimeInterval) async throws -> Void

    init(
        session: URLSession? = nil,
        retrySleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        injectedSession = session
        self.retrySleep = retrySleep
    }

    func data(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (Data, URLResponse) {
        try await AINetworkSession.withRetry(sleep: retrySleep) {
            do {
                let session = injectedSession ?? AINetworkSession.session(for: profile)
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw APIErrorBodyParser.httpError(response: http, body: data)
                }
                return (data, response)
            } catch {
                throw TransportErrorMapper.map(error)
            }
        }
    }

    func streamLines(
        for request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await AINetworkSession.withRetry(sleep: retrySleep) {
            do {
                let session = injectedSession ?? AINetworkSession.session(for: profile)
                let (bytes, response) = try await session.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    // Error responses are JSON, not SSE. Consume only a bounded
                    // prefix before retry classification, then release the task.
                    defer { bytes.task.cancel() }
                    var body = Data()
                    do {
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= APIErrorBodyParser.maximumBodyBytes { break }
                        }
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        // A truncated body must not hide an already known HTTP
                        // failure or its Retry-After header behind a read error.
                    }
                    throw APIErrorBodyParser.httpError(response: http, body: body)
                }
                return (bytes, response)
            } catch {
                throw TransportErrorMapper.map(error)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw AIProviderError.networkError("Invalid response")
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TransportErrorMapper.map(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return (httpResponse, stream)
    }
}
