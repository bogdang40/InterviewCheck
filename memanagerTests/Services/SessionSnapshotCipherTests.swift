import AppKit
import Security
import XCTest
@testable import memanager

final class SessionSnapshotCipherTests: XCTestCase {
    func testUnavailableSnapshotKeyDoesNotWriteReplacement() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            var writes = 0
            XCTAssertThrowsError(try SessionSnapshotCipher.resolveKey(
                read: { throw KeychainReadError(status: status) },
                save: { _ in writes += 1; return true }
            )) { error in
                XCTAssertEqual((error as? KeychainReadError)?.status, status)
            }
            XCTAssertEqual(writes, 0)
        }
    }

    func testExistingSnapshotKeyIsPreserved() throws {
        let stored = Data(repeating: 0x42, count: 32)
        var writes = 0
        let key = try XCTUnwrap(SessionSnapshotCipher.resolveKey(
            read: { stored },
            save: { _ in writes += 1; return true }
        ))
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, stored)
        XCTAssertEqual(writes, 0)
    }

    func testMalformedSnapshotKeyDoesNotWriteReplacement() throws {
        var writes = 0
        let key = try SessionSnapshotCipher.resolveKey(
            read: { Data([0x01]) },
            save: { _ in writes += 1; return true }
        )
        XCTAssertNil(key)
        XCTAssertEqual(writes, 0)
    }

    func testMissingSnapshotKeyIsSavedAndVerified() throws {
        var stored: Data?
        var reads = 0
        var writes = 0
        let key = try XCTUnwrap(SessionSnapshotCipher.resolveKey(
            read: { reads += 1; return stored },
            save: { stored = $0; writes += 1; return true }
        ))
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, stored)
        XCTAssertEqual(stored?.count, 32)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, 1)
    }

    func testSnapshotKeyRequiresSuccessfulPersistenceAndMatchingReadback() throws {
        var reads = 0
        XCTAssertNil(try SessionSnapshotCipher.resolveKey(
            read: { reads += 1; return nil },
            save: { _ in false }
        ))
        XCTAssertEqual(reads, 1)

        reads = 0
        XCTAssertNil(try SessionSnapshotCipher.resolveKey(
            read: { reads += 1; return reads == 1 ? nil : Data(repeating: 0x24, count: 32) },
            save: { _ in true }
        ))
        XCTAssertEqual(reads, 2)
    }

    func testEncryptedSnapshotDecryptsBackToImage() throws {
        let image = makeImage(size: NSSize(width: 24, height: 16))

        guard let encrypted = SessionSnapshotCipher.encryptSnapshot(image) else {
            return XCTFail("expected snapshot encryption to succeed")
        }

        let record = SessionSnapshotRecord(
            id: "snapshot-1",
            sessionId: "session-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: encrypted.width,
            height: encrypted.height,
            sizeBytes: encrypted.payload.count,
            source: "test",
            contentHash: encrypted.hash,
            encryptedPayload: encrypted.payload
        )

        let decrypted = SessionSnapshotCipher.decryptSnapshot(record)

        XCTAssertNotNil(decrypted)
        XCTAssertGreaterThan(decrypted?.size.width ?? 0, 0)
        XCTAssertGreaterThan(decrypted?.size.height ?? 0, 0)
    }

    func testInvalidSnapshotPayloadFailsClosed() {
        let record = SessionSnapshotRecord(
            id: "snapshot-2",
            sessionId: "session-1",
            capturedAt: Date(),
            width: 1,
            height: 1,
            sizeBytes: 4,
            source: "test",
            contentHash: "",
            encryptedPayload: Data([1, 2, 3, 4])
        )

        XCTAssertNil(SessionSnapshotCipher.decryptSnapshot(record))
    }

    private func makeImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}
