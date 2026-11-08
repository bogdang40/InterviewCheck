import XCTest
@testable import memanager

final class AccessAPIClientTests: XCTestCase {
    private final class StubTransport: AccessAPITransporting {
        var responses: [(Data, Int)] = []
        var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !responses.isEmpty else { throw AccessAPIError.network("no stub") }
            let (data, status) = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    private let signedInJSON = """
    {"token":"mm_abc","user":{"id":"u1","email":"a@b.c","role":"admin","disabled":false,"createdAt":"2026-01-01T00:00:00.000Z","trialEndsAt":null,"complimentaryUntil":null},
     "entitlement":{"active":true,"source":"admin","expiresAt":null,"graceUntil":"2026-09-09T12:00:00.000Z","plan":null,"subscriptionStatus":null},
     "subscription":null,"serverTime":"2026-09-02T12:00:00.000Z"}
    """

    func testLoginSendsCredentialsAndDecodesResponse() async throws {
        let transport = StubTransport()
        transport.responses = [(Data(signedInJSON.utf8), 200)]
        let client = AccessAPIClient(baseURLProvider: { "http://localhost:8787" }, transport: transport, deviceName: "Test Mac")

        let response = try await client.login(email: "a@b.c", password: "long-password!")

        XCTAssertEqual(response.token, "mm_abc")
        XCTAssertTrue(response.user.isAdmin)
        XCTAssertEqual(response.entitlement.source, .admin)
        XCTAssertEqual(try XCTUnwrap(response.entitlement.graceUntilDate).timeIntervalSince1970, 1_788_955_200, accuracy: 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8787/v1/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["email"] as? String, "a@b.c")
        XCTAssertEqual(body?["deviceName"] as? String, "Test Mac")
    }

    func testMeAttachesBearerTokenAndMapsServerErrors() async {
        let transport = StubTransport()
        transport.responses = [(Data("{\"error\":{\"code\":\"session_invalid\",\"message\":\"expired\"}}".utf8), 401)]
        let client = AccessAPIClient(baseURLProvider: { "localhost:8787" }, transport: transport)

        do {
            _ = try await client.me(token: "mm_token")
            XCTFail("expected an error")
        } catch let error as AccessAPIError {
            XCTAssertEqual(error, .server(status: 401, code: "session_invalid", message: "expired"))
            XCTAssertTrue(error.invalidatesSession)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer mm_token")
        XCTAssertEqual(transport.requests.first?.url?.scheme, "https", "bare hosts default to https")
    }

    func testBodyless401IsAServerErrorThatDoesNotInvalidateTheSession() async {
        let transport = StubTransport()
        transport.responses = [(Data(), 401)]
        let client = AccessAPIClient(baseURLProvider: { "http://localhost:8787" }, transport: transport)
        do {
            _ = try await client.me(token: "mm_token")
            XCTFail("expected an error")
        } catch let error as AccessAPIError {
            XCTAssertEqual(error, .server(status: 401, code: "http_401", message: "The access server answered with HTTP 401."))
            XCTAssertFalse(error.invalidatesSession)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testMissingTokenFailsBeforeHittingTheNetwork() async {
        let transport = StubTransport()
        let client = AccessAPIClient(baseURLProvider: { "http://localhost:8787" }, transport: transport)
        do {
            _ = try await client.me(token: "")
            XCTFail("expected an error")
        } catch let error as AccessAPIError {
            XCTAssertEqual(error, .unauthenticated)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCheckoutReturnsURLAndAdminPatchUsesPatchVerb() async throws {
        let transport = StubTransport()
        transport.responses = [
            (Data("{\"url\":\"https://checkout.stripe.test/cs_1\"}".utf8), 200),
            (Data("""
            {"user":{"id":"u2","email":"m@b.c","role":"user","disabled":false,"createdAt":"2026-01-01T00:00:00Z","trialEndsAt":null,"complimentaryUntil":"2026-10-01T00:00:00Z"},
             "entitlement":{"active":true,"source":"complimentary","expiresAt":"2026-10-01T00:00:00Z","graceUntil":"2026-09-09T00:00:00Z","plan":null,"subscriptionStatus":null},
             "subscription":null,"lastLoginAt":null}
            """.utf8), 200),
        ]
        let client = AccessAPIClient(baseURLProvider: { "http://localhost:8787" }, transport: transport)
        let url = try await client.checkoutURL(token: "mm_t", plan: "annual")
        XCTAssertEqual(url.host, "checkout.stripe.test")

        let admin = AdminAPIClient(client: client)
        let view = try await admin.update(token: "mm_t", userID: "u2", patch: AdminUserPatch(complimentaryUntil: .some(Date(timeIntervalSince1970: 0))))
        XCTAssertEqual(view.entitlement.source, .complimentary)
        XCTAssertEqual(transport.requests.last?.httpMethod, "PATCH")
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/admin/users/u2")
    }
}
