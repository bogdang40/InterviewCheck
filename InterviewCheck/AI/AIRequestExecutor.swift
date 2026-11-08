import Foundation

enum AIStreamChunkPolicy {
    case immediate
    case batched(interval: TimeInterval = 0.016, flushOnNewline: Bool = true)
}

final class AIRequestExecutor {
    private let transport: NetworkTransport

    init(transport: NetworkTransport = URLSessionNetworkTransport()) {
        self.transport = transport
    }

    func executeDataRequest(
        _ request: URLRequest,
        profile: AINetworkSession.SessionProfile
    ) async throws -> Data {
        let (data, response) = try await transport.data(for: request, profile: profile)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response")
        }
        if httpResponse.statusCode != 200 {
            throw APIErrorBodyParser.httpError(response: httpResponse, body: data)
        }
        return data
    }

    func executeStreamingTextRequest(
        _ request: URLRequest,
        profile: AINetworkSession.SessionProfile,
        chunkPolicy: AIStreamChunkPolicy,
        timeoutPolicy: StreamTimeoutPolicy? = nil,
        watchdogCheckInterval: TimeInterval = 1.0,
        lineParser: (Data) -> String?,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let (httpResponse, rawLines) = try await transport.streamLines(for: request, profile: profile)
        let lines = StreamWatchdog.monitored(
            rawLines,
            policy: timeoutPolicy ?? .policy(for: profile),
            checkInterval: watchdogCheckInterval
        )
        if httpResponse.statusCode != 200 {
            let body = try await captureErrorBody(from: lines)
            throw APIErrorBodyParser.httpError(response: httpResponse, body: body)
        }

        var fullText = ""
        let delivery = AIStreamTextDelivery(policy: chunkPolicy, onChunk: onChunk)
        // Flush before returning or throwing so already received text survives.
        defer { delivery.finish() }
        for try await line in lines {
            guard line.hasPrefix("data:") else { continue }
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") {
                payload.removeFirst()
            }
            if payload == "[DONE]" { break }
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
            if let error = APIErrorBodyParser.streamError(from: data) { throw error }
            guard let chunk = lineParser(data),
                  !chunk.isEmpty else { continue }

            fullText += chunk
            delivery.append(chunk)
        }

        return fullText
    }

    private func captureErrorBody(from lines: AsyncThrowingStream<String, Error>) async throws -> Data {
        var body = Data()
        do {
            for try await line in lines {
                let remaining = APIErrorBodyParser.maximumBodyBytes - body.count
                body.append(contentsOf: line.utf8.prefix(remaining))
                if body.count >= APIErrorBodyParser.maximumBodyBytes { break }
                body.append(10)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Keep the known HTTP failure if its body ends prematurely.
        }
        return body
    }
}
