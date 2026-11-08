import LocalAuthentication
import Security
import XCTest
@testable import memanager

final class KeychainReadPolicyTests: XCTestCase {
    func testMissingCredentialIsDistinctFromUnavailableStorage() throws {
        var calls = 0
        let value = try KeychainManager.readBinaryWithoutInteraction(key: "fixture") { _ in
            calls += 1
            return (errSecItemNotFound, nil)
        }
        XCTAssertNil(value)
        XCTAssertGreaterThanOrEqual(calls, 1)

        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            var deniedCalls = 0
            XCTAssertThrowsError(try KeychainManager.readBinaryWithoutInteraction(key: "fixture") { _ in
                deniedCalls += 1
                return (status, nil)
            }) { error in
                XCTAssertEqual((error as? KeychainReadError)?.status, status)
            }
            // Denial must not fall through to another keychain as if absent.
            XCTAssertEqual(deniedCalls, 1)
        }
    }

    func testSuccessfulReadReturnsOriginalDataAndStopsSearching() throws {
        let expected = Data([0x01, 0x02, 0x03])
        var calls = 0
        let actual = try KeychainManager.readBinaryWithoutInteraction(key: "fixture") { _ in
            calls += 1
            return (errSecSuccess, expected)
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulStatusWithoutDataIsCorruptionNotAbsence() {
        XCTAssertThrowsError(try KeychainManager.readBinaryWithoutInteraction(key: "fixture") { _ in
            (errSecSuccess, nil)
        }) { error in
            XCTAssertEqual((error as? KeychainReadError)?.status, errSecDecode)
        }
    }

    func testQueryScopesAuthenticationToOneCredential() throws {
        for dataProtection in [true, false] {
            let query = KeychainManager.noninteractiveReadQuery(key: "fixture", dataProtection: dataProtection)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.memanager.api")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "fixture")
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
            XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
            let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
            XCTAssertTrue(context.interactionNotAllowed)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, dataProtection ? true : nil)
        }
    }
}
