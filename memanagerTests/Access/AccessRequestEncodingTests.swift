import XCTest
@testable import memanager

final class AccessRequestEncodingTests: XCTestCase {
    func testDeviceNameIsTrimmedBoundedAndNeverEmpty() {
        XCTAssertEqual(AccessAPIClient.boundedDeviceName("  Abe's MacBook Pro  "), "Abe's MacBook Pro")
        XCTAssertEqual(AccessAPIClient.boundedDeviceName("   "), "Mac")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(AccessAPIClient.boundedDeviceName(long).count, AccessAPIClient.maximumDeviceNameLength)
    }

    func testPlusAndAmpersandInAQueryValueArePercentEncoded() throws {
        let endpoint = AccessAPIEndpoint.adminUsers(query: "a+b&c=d@x.io", cursor: nil)
        let request = try endpoint.makeRequest(baseURL: URL(string: "https://access.example.com")!, token: "t")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("q=a%2Bb%26c%3Dd%40x.io"), query)
        XCTAssertFalse(query.contains("+"), "a literal plus decodes to a space on the server")
        XCTAssertTrue(query.contains("limit=50"))
    }

    func testCursorAndQueryRoundTripThroughURLComponents() throws {
        let endpoint = AccessAPIEndpoint.adminUsers(query: "plain", cursor: "MTIz:abc")
        let request = try endpoint.makeRequest(baseURL: URL(string: "https://access.example.com")!, token: "t")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["q"], "plain")
        XCTAssertEqual(values["cursor"], "MTIz:abc")
    }
}
