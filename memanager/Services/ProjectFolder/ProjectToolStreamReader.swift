import Foundation

/// The tool endpoints send one JSON payload per SSE data line. Parsing stays
/// synchronous so text deltas arrive in order before the next network read.
enum ProjectToolStreamReader {
    private static let maximumEventBytes = 1_048_576
    private static let maximumResponseBytes = 8_388_608

    static func consume(
        _ request: URLRequest,
        transport: NetworkTransport,
        onPayload: (String) throws -> Bool
    ) async throws {
        try Task.checkCancellation()
        let (response, rawLines) = try await transport.streamLines(for: request, profile: .quickAssist)
        let lines = StreamWatchdog.monitored(rawLines, policy: .policy(for: .quickAssist))
        guard response.statusCode == 200 else {
            var preview = Data()
            var lineCount = 0
            for try await line in lines {
                try Task.checkCancellation()
                preview.append(contentsOf: line.utf8.prefix(APIErrorBodyParser.maximumBodyBytes - preview.count))
                lineCount += 1
                if preview.count >= APIErrorBodyParser.maximumBodyBytes || lineCount >= 32 { break }
            }
            throw APIErrorBodyParser.httpError(response: response, body: preview)
        }
        var totalBytes = 0
        for try await line in lines {
            try Task.checkCancellation()
            let bytes = line.utf8.count
            totalBytes += bytes
            guard bytes <= maximumEventBytes, totalBytes <= maximumResponseBytes else {
                throw AIProviderError.parsingError("Project tool stream exceeded its response size limit.")
            }
            guard line.hasPrefix("data:") else { continue }
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            guard !payload.isEmpty else { continue }
            if let error = APIErrorBodyParser.streamError(from: Data(payload.utf8)) { throw error }
            if try onPayload(payload) { return }
        }
        try Task.checkCancellation()
        // The provider assembler validates its own terminal event after EOF.
    }
}
