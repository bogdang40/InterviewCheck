import Foundation

/// A Model Context Protocol client over streamable HTTP: JSON-RPC by POST,
/// answers as JSON or as a server-sent-events stream.
public actor MCPClient {
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
    }

    public static let protocolVersion = "2025-06-18"
    private let url: URL
    private let transport: HTTPTransport
    private let token: AccessTokenProvider?
    private var sessionID: String?
    private var nextID = 1
    private var initialized = false
    /// The version the server agreed to in `initialize` (sent on every call after).
    private(set) var negotiatedVersion = MCPClient.protocolVersion

    public init(url: URL, transport: HTTPTransport, token: AccessTokenProvider?) {
        self.url = url
        self.transport = transport
        self.token = token
    }

    public func listTools() async throws -> [Tool] {
        try await ensureInitialized()
        var tools: [Tool] = []
        var cursor: String?
        for _ in 0..<10 {
            let result = try await request("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
            tools += result["tools"].array.compactMap { tool in
                tool["name"].string.map { Tool(name: $0, description: tool["description"].string ?? "", inputSchema: tool["inputSchema"]) }
            }
            guard let next = result["nextCursor"].string else { break }
            cursor = next
        }
        return tools
    }

    /// Calls a tool; returns its structured content, or its text parsed as
    /// JSON when possible, or the text itself.
    public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await ensureInitialized()
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
        let text = result["content"].array.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n")
        if result["isError"].bool == true {
            throw ConnectorError.invalidResponse("\(name): \(text.prefix(200))")
        }
        if !result["structuredContent"].isNull { return result["structuredContent"] }
        return (try? JSONValue.parse(Data(text.utf8))) ?? .string(text)
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion), "capabilities": [:],
            "clientInfo": ["name": "InterviewCheck", "version": "1.0"],
        ])
        if let agreed = result["protocolVersion"].string { negotiatedVersion = agreed }
        initialized = true
        try await notify("notifications/initialized")
    }

    private func headers() async throws -> [String: String] {
        var headers = ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": negotiatedVersion]
        if let token { headers["Authorization"] = "Bearer \(try await token())" }
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        return headers
    }

    private func notify(_ method: String) async throws {
        let client = APIClient(baseURL: url, headers: try await headers(), transport: transport)
        _ = try await client.send(method: "POST", url: url, body: try JSONValue.object(["jsonrpc": "2.0", "method": .string(method)]).encoded())
    }

    private func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var client = APIClient(baseURL: url, headers: try await headers(), transport: transport)
        client.maxRetries = 1
        let body: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        let (data, response) = try await client.send(method: "POST", url: url, body: try body.encoded())
        if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        let message = try Self.message(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", id: id)
        if !message["error"].isNull {
            throw ConnectorError.invalidResponse("\(method): \(message.at("error.message").string ?? "error")")
        }
        return message["result"]
    }

    /// The JSON-RPC answer with this id, from a JSON body or an SSE stream.
    static func message(from data: Data, contentType: String, id: Int) throws -> JSONValue {
        let isAnswer = { (message: JSONValue) in
            message["id"].double == Double(id) && (!message["result"].isNull || !message["error"].isNull)
        }
        guard contentType.contains("text/event-stream") else {
            let message = try JSONValue.parse(data)
            // A batch, or a single answer.
            if case .array(let items) = message, let answer = items.first(where: isAnswer) { return answer }
            return message
        }
        var payload = ""
        var messages: [JSONValue] = []
        // SSE allows CRLF, LF or CR line endings.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("data:") {
                payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty, !payload.isEmpty {
                if let message = try? JSONValue.parse(Data(payload.utf8)) { messages.append(message) }
                payload = ""
            }
        }
        if !payload.isEmpty, let message = try? JSONValue.parse(Data(payload.utf8)) { messages.append(message) }
        // Notifications and progress events may come first: only the answer counts.
        guard let answer = messages.first(where: isAnswer) else {
            throw ConnectorError.invalidResponse("no answer in the event stream")
        }
        return answer
    }
}
