import Foundation

/// Interviews through a Model Context Protocol server: a vendor's own
/// (Greenhouse, Ashby, Workable) or any company server. The interview tool is
/// picked by name and its result read with InterviewJSONMapper.
public struct MCPConnector: InterviewSource {
    public let kind: ConnectorKind
    private let client: MCPClient
    private let url: URL

    /// Tool names known to list interviews, most specific first, with how
    /// to call them.
    static let interviewTools: [(name: String, arguments: (Date, Date) -> [String: JSONValue])] = [
        ("get_upcoming_interviews", { _, _ in [:] }),
        ("get_events", { start, end in ["type": "interview", "start_date": .string(DateParsing.iso(start)),
                                        "end_date": .string(DateParsing.iso(end))] }),
        ("list_interviews", { start, end in ["starts_after": .string(DateParsing.iso(start)), "starts_before": .string(DateParsing.iso(end))] }),
        ("list_scheduled_interviews", { _, _ in [:] }),
        ("search_interviews", { _, _ in [:] }),
    ]

    public init(kind: ConnectorKind, credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let url = URL(string: credentials["url"] ?? MCPPresets.url(for: kind) ?? ""), url.scheme == "https" else {
            throw ConnectorError.missingCredential("the server's https URL")
        }
        self.kind = kind
        self.url = url
        let staticToken = credentials["token"]
        let token: AccessTokenProvider? = accessToken ?? staticToken.map { value in { value } }
        client = MCPClient(url: url, transport: transport, token: token)
    }

    public func tools() async throws -> [MCPClient.Tool] {
        try await client.listTools()
    }

    public func verify() async throws -> String {
        let tools = try await client.listTools()
        let interviews = tools.contains { tool in Self.interviewTools.contains { $0.name == tool.name } }
        return "\(url.host ?? "MCP") \u{00B7} \(tools.count) tools\(interviews ? "" : ", none for interviews")"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let available = Set(try await client.listTools().map(\.name))
        guard let tool = Self.interviewTools.first(where: { available.contains($0.name) }) else { return [] }
        let result = try await client.callTool(tool.name, arguments: tool.arguments(start, end))
        return InterviewJSONMapper.interviews(in: result, source: kind).filter { $0.startsAt >= start && $0.startsAt <= end }
    }
}

/// Official vendor MCP servers (Nov 2026).
public enum MCPPresets {
    public static func url(for kind: ConnectorKind) -> String? {
        switch kind {
        case .greenhouseMCP: return "https://mcp.greenhouse.io/mcp"
        case .ashbyMCP: return "https://mcp.ashbyhq.com/mcp/v1"
        case .workableMCP: return "https://mcp.workable.com/mcp"
        default: return nil
        }
    }
}
