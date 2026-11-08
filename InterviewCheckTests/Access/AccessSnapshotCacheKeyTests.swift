import CryptoKit
import Security
import XCTest
@testable import InterviewCheck

final class AccessSnapshotCacheKeyTests: XCTestCase {
    func testInaccessibleKeyIsNeverReplaced() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            var writes = 0
            let key = UserDefaultsAccessSnapshotCache.resolveMacKey(
                read: { throw KeychainReadError(status: status) },
                save: { _ in writes += 1; return true }
            )
            XCTAssertNil(key)
            XCTAssertEqual(writes, 0)
        }
    }

    func testExistingKeyIsRetainedAndMalformedKeyIsNeverReplaced() {
        for count in [0, 31, 32, 33] {
            var writes = 0
            let bytes = Data(repeating: 7, count: count)
            let key = UserDefaultsAccessSnapshotCache.resolveMacKey(
                read: { bytes },
                save: { _ in writes += 1; return true }
            )
            XCTAssertEqual(key?.withUnsafeBytes { Data($0) }, count == 32 ? bytes : nil)
            XCTAssertEqual(writes, 0)
        }
    }

    func testAbsentKeyIsCreatedOnlyWhenStorageSucceeds() {
        var stored: Data?
        let key = UserDefaultsAccessSnapshotCache.resolveMacKey(read: { nil }, save: { stored = $0; return true })
        XCTAssertEqual(stored?.count, 32)
        XCTAssertEqual(key?.withUnsafeBytes { Data($0) }, stored)
        XCTAssertNil(UserDefaultsAccessSnapshotCache.resolveMacKey(read: { nil }, save: { _ in false }))
    }
}
