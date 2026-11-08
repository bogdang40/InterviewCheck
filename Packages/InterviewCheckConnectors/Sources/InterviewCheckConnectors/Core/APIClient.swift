import Foundation

/// Sends requests; URLSession in the app, a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a body to a temporary file (large recordings never sit in memory).
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension HTTPTransport {
    /// Transports without streaming (test stubs) write what they received.
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-\(UUID().uuidString)")
        try data.write(to: file)
        return (file, response)
    }
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse("not HTTP") }
        return (data, http)
    }

    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse("not HTTP") }
        return (url, http)
    }
}

/// A small JSON API client: base URL, fixed headers, retries on 429/503
/// using Retry-After, and errors mapped to ConnectorError.
public struct APIClient: Sendable {
    public var baseURL: URL
    public var headers: [String: String]
    public var transport: HTTPTransport
    public var maxRetries = 2
    /// Waits between retries; tests replace it so they never sleep.
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 30)) * 1_000_000_000))
    }

    public init(baseURL: URL, headers: [String: String] = [:], transport: HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.headers = headers
        self.transport = transport
    }

    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let base = path.hasPrefix("http") ? URL(string: path)! : baseURL.appendingPathComponent(path)
        guard !query.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = (components.queryItems ?? []) + query
        // "+" in ISO dates must stay a plus, not become a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "GET", url: url(path, query: query), body: nil)
    }

    public func getJSON(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try JSONValue.parse(try await get(path, query: query).0)
    }

    public func postJSON(_ path: String, body: JSONValue, query: [URLQueryItem] = [],
                         contentType: String = "application/json") async throws -> JSONValue {
        let (data, _) = try await send(method: "POST", url: url(path, query: query), body: try body.encoded(), contentType: contentType)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    public func postForm(_ path: String, fields: [String: String]) async throws -> JSONValue {
        let body = fields.sorted { $0.key < $1.key }
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        let (data, _) = try await send(method: "POST", url: url(path), body: Data(body.utf8),
                                       contentType: "application/x-www-form-urlencoded")
        return try JSONValue.parse(data)
    }

    public func send(method: String, url: URL, body: Data?, contentType: String = "application/json")
        async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        var attempt = 0
        while true {
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                return (data, response)
            case 429 where attempt < maxRetries, 503 where attempt < maxRetries:
                attempt += 1
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? Double(attempt * 2)
                try await sleep(wait)
            case 429:
                throw ConnectorError.rateLimited
            case 401:
                throw ConnectorError.unauthorized
            case 403:
                throw ConnectorError.forbidden(Self.message(data))
            case 404:
                throw ConnectorError.notFound
            default:
                throw ConnectorError.http(response.statusCode, Self.message(data))
            }
        }
    }

    /// The `next` URL from an RFC 8288 Link header, used by several APIs.
    public static func nextLink(_ response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: "\"", with: "") == "rel=next" }),
                  let first = pieces.first, first.hasPrefix("<"), first.hasSuffix(">") else { continue }
            return URL(string: String(first.dropFirst().dropLast()))
        }
        return nil
    }

    static func message(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// "Basic base64(user:password)".
    public static func basic(_ user: String, _ password: String = "") -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}
