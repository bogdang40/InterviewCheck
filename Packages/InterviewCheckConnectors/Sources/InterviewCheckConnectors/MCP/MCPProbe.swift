import Foundation

/// Sends discovery requests without APIClient's error mapping, so a 401's
/// headers can be read, and returns the real status for the caller to check.
struct MCPProbe: Sendable {
    let transport: HTTPTransport

    func send(method: String, url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await transport.send(request)
    }

    /// The body of a 200 reply, or nil for any other status or a failure.
    func json(at url: URL) async -> JSONValue? {
        guard let (data, response) = try? await send(method: "GET", url: url), response.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }
}
