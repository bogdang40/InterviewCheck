import XCTest
@testable import InterviewCheckConnectors

final class LoopbackAndSessionTests: XCTestCase {
    func testCallbackIsReceivedEvenBeforeWaiting() async throws {
        let receiver = try LoopbackReceiver()
        let redirect = try await receiver.start()
        // The browser comes back before the app starts waiting.
        _ = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "?code=abc&state=s")!)
        let callback = try await receiver.waitForCallback(timeout: 5)
        XCTAssertEqual(try LoopbackReceiver.code(from: callback, expectedState: "s"), "abc")
    }

    func testRequestsWithoutTheRightStateAreIgnored() async throws {
        let receiver = try LoopbackReceiver(expectedState: "s")
        let redirect = try await receiver.start()
        // Any local page can request these; none of them may end the sign-in.
        for stray in ["?error=access_denied", "?error=access_denied&state=other", "?code=evil", "?code=evil&state=other"] {
            _ = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + stray)!)
        }
        _ = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "?code=abc&state=s")!)
        let callback = try await receiver.waitForCallback(timeout: 5)
        XCTAssertEqual(try LoopbackReceiver.code(from: callback, expectedState: "s"), "abc")
    }

    func testStateIsCheckedBeforeAnError() {
        let forged = URL(string: "http://127.0.0.1:5555/callback?error=access_denied&state=other")!
        XCTAssertThrowsError(try LoopbackReceiver.code(from: forged, expectedState: "s")) { error in
            XCTAssertEqual(error as? ConnectorError, .unsupported("Sign-in state did not match."))
        }
    }

    func testCancellingTheWaitEndsItAtOnce() async throws {
        let receiver = try LoopbackReceiver()
        _ = try await receiver.start()
        let wait = Task { try await receiver.waitForCallback(timeout: 300) }
        try await Task.sleep(nanoseconds: 100_000_000)
        wait.cancel()
        let started = Date()
        do {
            _ = try await wait.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let stub = StubTransport()
        stub.on("POST", "googleapis.com/token", json: #"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#)
        let client = OAuthClient(provider: GoogleConnectorProvider.provider, clientID: "c", transport: stub)
        let saved = SavedTokens()
        let session = OAuthSession(tokens: OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast),
                                   client: client, onUpdate: { saved.append($0) })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await session.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(tokens), ["new"])
        XCTAssertEqual(stub.requests(containing: "token").count, 1, "the refresh token is spent once")
        XCTAssertEqual(saved.count, 1)
        let again = try await session.accessToken()
        XCTAssertEqual(again, "new")
        XCTAssertEqual(stub.requests(containing: "token").count, 1, "a valid token is reused")
    }

    func testSSEWithCRLFAndANotificationFirst() throws {
        let stream = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n\r\n"
            + "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\r\n\r\n"
        let message = try MCPClient.message(from: Data(stream.utf8), contentType: "text/event-stream", id: 7)
        XCTAssertEqual(message.at("result.ok").bool, true)
        XCTAssertThrowsError(try MCPClient.message(from: Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"x\"}\n\n".utf8),
                                                   contentType: "text/event-stream", id: 7), "a notification is not an answer")
    }

    func testMapperReadsStringCandidatesAndSnakeCase() throws {
        let json = try JSONValue.parse(Data(#"[{"id":"a","start_time":"2026-11-10T15:00:00Z","candidate":"Jane Doe"},{"id":"b","start_time":"2026-11-11T15:00:00Z","candidate":{"first_name":"Lee","last_name":"Park","email_addresses":[{"value":"lee@x.com"}]}}]"#.utf8))
        let interviews = InterviewJSONMapper.interviews(in: json, source: .mcp)
        XCTAssertEqual(interviews.map(\.candidate?.name), ["Jane Doe", "Lee Park"])
        XCTAssertEqual(interviews[1].candidate?.email, "lee@x.com")
    }
}

final class SavedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OAuthTokens] = []
    func append(_ tokens: OAuthTokens) { lock.lock(); items.append(tokens); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}
