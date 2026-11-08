import XCTest
@testable import InterviewCheckConnectors

final class CoreTests: XCTestCase {
    func testClientRetriesOn429ThenMapsErrors() async throws {
        let stub = StubTransport()
        stub.on("GET", "/things", status: 429, headers: ["Retry-After": "3"])
        stub.on("GET", "/things", json: #"{"ok":true}"#)
        var client = APIClient(baseURL: URL(string: "https://api.example.com/v1")!, headers: ["Authorization": "Bearer x"],
                               transport: stub)
        let waits = WaitLog()
        client.sleep = { await waits.add($0) }
        let json = try await client.getJSON("things", query: [URLQueryItem(name: "after", value: "2026-11-08T10:00:00+01:00")])
        XCTAssertEqual(json["ok"].bool, true)
        let recorded = await waits.values
        XCTAssertEqual(recorded, [3])
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("after=2026-11-08T10:00:00%2B01:00"), "plus stays a plus")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer x")

        stub.on("GET", "/denied", status: 401)
        stub.on("GET", "/gone", status: 404)
        stub.on("GET", "/broken", status: 500, json: "server exploded")
        await XCTAssertThrowsAsync(try await client.get("denied"), .unauthorized)
        await XCTAssertThrowsAsync(try await client.get("gone"), .notFound)
        await XCTAssertThrowsAsync(try await client.get("broken"), .http(500, "server exploded"))
    }

    func testLinkHeaderAndJSONPaths() throws {
        let response = HTTPURLResponse(url: URL(string: "https://x.io")!, statusCode: 200, httpVersion: nil, headerFields: [
            "Link": #"<https://x.io/v1/a?page=2>; rel="next", <https://x.io/v1/a?page=9>; rel="last""#,
        ])!
        XCTAssertEqual(APIClient.nextLink(response)?.absoluteString, "https://x.io/v1/a?page=2")
        let json = try JSONValue.parse(Data(#"{"a":{"b":[{"c":"d","n":42}]}}"#.utf8))
        XCTAssertEqual(json.at("a.b.0.c").string, "d")
        XCTAssertEqual(json.at("a.b.0.n").string, "42")
        XCTAssertTrue(json.at("a.x.y").isNull)
        XCTAssertEqual(APIClient.basic("key"), "Basic " + Data("key:".utf8).base64EncodedString())
    }

    func testDates() {
        XCTAssertEqual(DateParsing.parse("2026-11-08T15:00:00Z")?.timeIntervalSince1970, 1_794_150_000)
        XCTAssertEqual(DateParsing.parse("2026-11-08T15:00:00.250Z")?.timeIntervalSince1970 ?? 0, 1_794_150_000.25, accuracy: 0.001)
        XCTAssertEqual(DateParsing.parse("1794150000000")?.timeIntervalSince1970, 1_794_150_000)
        XCTAssertNotNil(DateParsing.parse("2026-11-08"))
    }

    func testHTMLToText() {
        let escaped = "&lt;p&gt;We build &lt;strong&gt;payments&lt;/strong&gt;.&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Go&lt;/li&gt;&lt;li&gt;Postgres &amp;amp; Redis&lt;/li&gt;&lt;/ul&gt;"
        XCTAssertEqual(HTMLText.plain(escaped), "We build payments.\n\n\u{2022} Go\n\u{2022} Postgres & Redis")
        XCTAssertEqual(HTMLText.plain("<div>A<br>B&nbsp;&#8212; C&#x27;s</div><script>x()</script>"), "A\nB \u{2014} C's")
    }

    func testMeetingLinks() {
        let notes = """
        Join: https://acme.zoom.us/j/81234567890?pwd=abc123. Backup: https://meet.google.com/abc-defg-hij
        """
        XCTAssertEqual(MeetingLinks.first(in: [nil, notes])?.absoluteString, "https://acme.zoom.us/j/81234567890?pwd=abc123")
        let teams = "<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d>"
        XCTAssertEqual(MeetingLinks.platform(of: MeetingLinks.first(in: [teams])!), .teams)
        XCTAssertEqual(MeetingLinks.first(in: ["Room 4B"]), nil)
    }

    func testPKCEChallengeIsBase64URLSHA256() {
        // Expected value computed independently with openssl dgst -sha256 | base64url.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mJ92IFH5Sav2VjvQDaCtZQ3rIsJbRk"),
                       "bhR0fEG5i6WDIbkqcZogvBKc6yfNt3F64HSgCf6qx5U")
        XCTAssertGreaterThanOrEqual(PKCE.verifier().count, 43)
    }

    func testOAuthExchangeRefreshAndCallback() async throws {
        let stub = StubTransport()
        stub.on("POST", "googleapis.com/token", json: #"{"access_token":"a1","refresh_token":"r1","expires_in":3600,"scope":"cal"}"#)
        var client = OAuthClient(provider: GoogleConnectorProvider.provider, clientID: "cid", clientSecret: "sec", transport: stub)
        client.now = { Date(timeIntervalSince1970: 1_000) }
        let redirect = URL(string: "http://127.0.0.1:5555/callback")!
        let url = client.authorizationURL(redirectURI: redirect, state: "s1", codeChallenge: "ch")
        XCTAssertTrue(url.absoluteString.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.absoluteString.contains("access_type=offline"))

        let code = try LoopbackReceiver.code(from: URL(string: "http://127.0.0.1:5555/callback?code=c9&state=s1")!, expectedState: "s1")
        let tokens = try await client.exchange(code: code, verifier: "v", redirectURI: redirect)
        XCTAssertEqual(tokens, OAuthTokens(accessToken: "a1", refreshToken: "r1",
                                           expiresAt: Date(timeIntervalSince1970: 4_600), scope: "cal"))
        let form = String(decoding: stub.requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("code=c9") && form.contains("code_verifier=v") && form.contains("client_secret=sec"))
        XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2Fcallback"))

        XCTAssertThrowsError(try LoopbackReceiver.code(from: URL(string: "http://x/callback?code=c&state=other")!, expectedState: "s1"))
        XCTAssertThrowsError(try LoopbackReceiver.code(from: URL(string: "http://x/callback?error=access_denied&state=s1")!, expectedState: "s1"))
        XCTAssertEqual(LoopbackReceiver.requestTarget("GET /callback?code=1 HTTP/1.1\r\nHost: x\r\n\r\n"), "/callback?code=1")

        // A refresh that omits the refresh token keeps the old one.
        let refreshStub = StubTransport()
        refreshStub.on("POST", "googleapis.com/token", json: #"{"access_token":"a2","expires_in":3600}"#)
        client.transport = refreshStub
        let expired = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date(timeIntervalSince1970: 1_030))
        let refreshed = try await client.fresh(expired)
        XCTAssertEqual(refreshed.accessToken, "a2")
        XCTAssertEqual(refreshed.refreshToken, "r1")
        XCTAssertTrue(String(decoding: refreshStub.requests[0].httpBody!, as: UTF8.self).contains("grant_type=refresh_token"))
        let valid = OAuthTokens(accessToken: "a3", expiresAt: Date(timeIntervalSince1970: 9_000))
        let unchanged = try await client.fresh(valid)
        XCTAssertEqual(unchanged.accessToken, "a3", "a token that is still valid is not refreshed")
    }

    func testMemoryCredentialStore() throws {
        let store = MemoryCredentialStore()
        try store.save(ConnectorCredentials(fields: ["apiKey": " k "]), for: "greenhouse")
        XCTAssertEqual(store.load("greenhouse")?["apiKey"], "k")
        XCTAssertThrowsError(try ConnectorCredentials().required("apiKey", "API key"))
        store.delete("greenhouse")
        XCTAssertNil(store.load("greenhouse"))
    }

    func testCatalogCoversEveryKind() {
        XCTAssertEqual(ConnectorCatalog.all.count, ConnectorKind.allCases.count)
        XCTAssertTrue(ConnectorCatalog.all.allSatisfy { !$0.name.isEmpty && !$0.summary.isEmpty && !$0.setup.isEmpty })
        XCTAssertEqual(ConnectorKind.greenhouseMCP.descriptor.vendorName, "Greenhouse")
        XCTAssertEqual(ConnectorKind.microsoft365.descriptor.vendorName, "Microsoft 365")
        XCTAssertEqual(ConnectorCategory.allCases.first, .calendar, "no-setup sources are listed first")
    }
}

actor WaitLog {
    var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ expected: ConnectorError,
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("did not throw", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ConnectorError, expected, file: file, line: line)
    }
}
