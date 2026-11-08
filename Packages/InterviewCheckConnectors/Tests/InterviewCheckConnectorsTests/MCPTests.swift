import XCTest
@testable import InterviewCheckConnectors

final class MCPTests: XCTestCase {
    private let server = "https://mcp.example.com/mcp"

    private func mcpStub(toolsResult: String, callResult: String, sse: Bool = false) -> StubTransport {
        let stub = StubTransport()
        stub.on("POST", server, json: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"test"}}}"#,
                headers: ["Mcp-Session-Id": "sess-1", "Content-Type": "application/json"], bodyContains: "\"initialize\"")
        stub.on("POST", server, status: 202, json: "", bodyContains: "notifications/initialized")
        stub.on("POST", server, json: toolsResult, headers: ["Content-Type": "application/json"], bodyContains: "tools/list")
        stub.on("POST", server, json: callResult, headers: ["Content-Type": sse ? "text/event-stream" : "application/json"],
                bodyContains: "tools/call")
        return stub
    }

    func testHandshakeSessionHeaderToolsAndSSEResult() async throws {
        let call = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[{\\\"id\\\":\\\"e1\\\",\\\"startTime\\\":\\\"2026-11-10T15:00:00Z\\\",\\\"candidate\\\":{\\\"name\\\":\\\"Adam Hart\\\"}}]\"}]}}\n\n"
        let stub = mcpStub(toolsResult: #"{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"get_upcoming_interviews","description":"Upcoming interviews","inputSchema":{"type":"object"}}]}}"#,
                           callResult: call, sse: true)
        let client = MCPClient(url: URL(string: server)!, transport: stub, token: { "tok" })
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["get_upcoming_interviews"])
        let result = try await client.callTool("get_upcoming_interviews", arguments: [:])
        XCTAssertEqual(result[0]["id"].string, "e1")

        XCTAssertNil(stub.requests[0].value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(stub.requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        XCTAssertEqual(stub.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(stub.requests[2].value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertEqual(stub.requests.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("\"initialize\"") }.count, 1)
    }

    func testToolErrorsAndRPCErrorsSurface() async throws {
        let stub = mcpStub(toolsResult: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no tools"}}"#,
                           callResult: #"{"jsonrpc":"2.0","id":4,"result":{"isError":true,"content":[{"type":"text","text":"forbidden scope"}]}}"#)
        let client = MCPClient(url: URL(string: server)!, transport: stub, token: nil)
        do { _ = try await client.listTools(); XCTFail("should throw") } catch {
            XCTAssertTrue(error.localizedDescription.contains("no tools"))
        }
        do { _ = try await client.callTool("x", arguments: [:]); XCTFail("should throw") } catch {
            XCTAssertTrue(error.localizedDescription.contains("forbidden scope"))
        }
    }

    func testConnectorPicksTheInterviewToolAndMapsResults() async throws {
        let workable = #"{"jsonrpc":"2.0","id":4,"result":{"structuredContent":{"events":[{"id":"47fdddd","title":"Interview with Wayne Walsh","starts_at":"2026-11-10T22:00:00.000Z","ends_at":"2026-11-10T22:30:00.000Z","candidate":{"id":"2b50","name":"Wayne Walsh"},"job":{"shortcode":"GROOV001","title":"Operations Manager"},"conference":{"url":"https://zoom.us/j/1100001"}},{"id":"old","starts_at":"2026-01-01T10:00:00Z","title":"Interview"}]}}}"#
        let stub = mcpStub(toolsResult: #"{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"get_jobs"},{"name":"get_events"}]}}"#, callResult: workable)
        let connector = try MCPConnector(kind: .workableMCP, credentials: ConnectorCredentials(fields: ["url": server]),
                                         transport: stub, accessToken: { "t" })
        let interviews = try await connector.upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        XCTAssertEqual(interviews.map(\.externalID), ["47fdddd"])
        XCTAssertEqual(interviews[0].candidate?.name, "Wayne Walsh")
        XCTAssertEqual(interviews[0].job?.externalID, "GROOV001")
        XCTAssertEqual(interviews[0].meetingURL?.host, "zoom.us")
        let call = stub.bodyJSON(try XCTUnwrap(stub.requests.first { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("tools/call") }))
        XCTAssertEqual(call.at("params.name").string, "get_events")
        XCTAssertEqual(call.at("params.arguments.type").string, "interview")
    }

    func testMapperIgnoresObjectsThatAreNotInterviews() {
        let json = try! JSONValue.parse(Data(#"{"jobs":[{"id":"j","title":"Engineer","created_at":"2026-01-01T00:00:00Z"}],"page":{"date":"x"},"data":{"items":[{"interviewId":"i9","startAt":"2026-11-12T09:00:00Z","candidateName":"Lee Park","meetingLink":"https://meet.google.com/abc-defg-hij"}]}}"#.utf8))
        let interviews = InterviewJSONMapper.interviews(in: json, source: .mcp)
        XCTAssertEqual(interviews.map(\.externalID), ["i9"], "a job with only a creation date is not an interview")
        XCTAssertEqual(interviews.first?.meetingURL?.host, "meet.google.com")
    }

    func testOAuthDiscoveryAndRegistration() async throws {
        let stub = StubTransport()
        stub.on("GET", "/.well-known/oauth-protected-resource", json: #"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["mcp:read"]}"#)
        stub.on("GET", "auth.example.com/.well-known/oauth-authorization-server", json: #"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register"}"#)
        stub.on("POST", server, status: 401, json: "", headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#])
        stub.on("POST", "auth.example.com/register", status: 201, json: #"{"client_id":"dyn-123"}"#)
        let endpoints = try await MCPAuthorization.discover(server: URL(string: server)!, transport: stub)
        XCTAssertEqual(endpoints.tokenURL.absoluteString, "https://auth.example.com/token")
        XCTAssertEqual(endpoints.scopes, ["mcp:read"])
        let redirect = URL(string: "http://127.0.0.1:5123/callback")!
        let clientID = try await MCPAuthorization.register(at: try XCTUnwrap(endpoints.registrationURL), redirectURI: redirect, transport: stub)
        XCTAssertEqual(clientID, "dyn-123")
        let registration = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/register").first))
        XCTAssertEqual(registration["token_endpoint_auth_method"].string, "none")
        XCTAssertEqual(registration["redirect_uris"][0].string, redirect.absoluteString)

        let provider = MCPAuthorization.provider(endpoints, server: URL(string: server)!)
        let url = OAuthClient(provider: provider, clientID: clientID, transport: stub)
            .authorizationURL(redirectURI: redirect, state: "s", codeChallenge: "c").absoluteString
        XCTAssertTrue(url.contains("resource=https://mcp.example.com/mcp") || url.contains("resource=https%3A%2F%2Fmcp.example.com%2Fmcp"))
    }
}
