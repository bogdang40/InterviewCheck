import XCTest
@testable import memanager

/// Cross language vector: these envelopes were produced by the Node signing
/// tool (server/src/owner/OwnerLicenseSigner.ts) with a throwaway key, so
/// the Swift verifier is proven against the real issuer, not a Swift mock.
final class OwnerLicenseVerifierTests: XCTestCase {
    static let publicKey = "nilrIkOEdemOs2nMa1fWZmd7otpVmWfsYihCEIFhYnA="
    static let otherPublicKey = "3xhbSXd+Mh6yH4s+CMoolE7QjClFEXwDX+YfWDhgt0w="
    static let device = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"
    static let open = OwnerLicenseEnvelope(
        payload: "eyJ2ZXJzaW9uIjoxLCJlbWFpbCI6Im93bmVyQGV4YW1wbGUuY29tIiwiZGV2aWNlSUQiOiIwQTFCMkMzRC00RTVGLTYwNzEtODI5My1BNEI1QzZEN0U4RjkiLCJpc3N1ZWRBdCI6IjIwMjYtMDktMDNUMTI6MDA6MDAuMDAwWiIsImV4cGlyZXNBdCI6bnVsbCwibm90ZSI6InRlc3QgdmVjdG9yIn0=",
        signature: "VIq0Xi2KOfog7KS419wIpNoaB8/5ytq1p8yfbMPc21lZ1VMA9eE0vvi78umvi2YINYtG8ONp8ncUvWl9g04lBA=="
    )
    static let expiring = OwnerLicenseEnvelope(
        payload: "eyJ2ZXJzaW9uIjoxLCJlbWFpbCI6Im93bmVyQGV4YW1wbGUuY29tIiwiZGV2aWNlSUQiOiIwQTFCMkMzRC00RTVGLTYwNzEtODI5My1BNEI1QzZEN0U4RjkiLCJpc3N1ZWRBdCI6IjIwMjYtMDktMDNUMTI6MDA6MDAuMDAwWiIsImV4cGlyZXNBdCI6IjIwMjYtMTAtMDFUMDA6MDA6MDAuMDAwWiIsIm5vdGUiOm51bGx9",
        signature: "Dji8nESIeJxVEgyL4qnx4gvyR07F91341FxwNr63cSxBGD1GGXV/pCGPmepuUgFSaIv9r6CQbm9JrKrDMpEBCQ=="
    )

    /// Same key, expiresAt set to the string "never": signed, so only the
    /// date check can reject it.
    static let badExpiry = OwnerLicenseEnvelope(
        payload: "eyJ2ZXJzaW9uIjoxLCJlbWFpbCI6Im93bmVyQGV4YW1wbGUuY29tIiwiZGV2aWNlSUQiOiIwQTFCMkMzRC00RTVGLTYwNzEtODI5My1BNEI1QzZEN0U4RjkiLCJpc3N1ZWRBdCI6IjIwMjYtMDktMDNUMTI6MDA6MDAuMDAwWiIsImV4cGlyZXNBdCI6Im5ldmVyIiwibm90ZSI6InRlc3QgdmVjdG9yIn0=",
        signature: "t0y1N7DpszIK5ti+tmYhhzwV5Bz0KNL9lv1z2gGs977FNwvPKiolVuyHHK2lyja10V2omkSU1EaINjE/oY5ECA=="
    )

    private let now = ISO8601DateParser.parse("2026-09-03T12:00:00Z")!
    private let verifier = OwnerLicenseVerifier(publicKeyBase64: OwnerLicenseVerifierTests.publicKey)

    static func data(_ envelope: OwnerLicenseEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    func testVectorFromTheNodeToolVerifiesAndDeviceComparisonIsCaseInsensitive() throws {
        let license = try verifier.verify(Self.data(Self.open), deviceID: Self.device.lowercased(), now: now)
        XCTAssertEqual(license.version, 1)
        XCTAssertEqual(license.email, "owner@example.com")
        XCTAssertEqual(license.deviceID, Self.device)
        XCTAssertEqual(license.note, "test vector")
        XCTAssertNil(license.expiresAt)
        XCTAssertEqual(license.issuedAtDate, now)
    }

    func testLicenseBoundToAnotherMacIsRefused() throws {
        XCTAssertThrowsError(try verifier.verify(Self.data(Self.open), deviceID: "FFFFFFFF-0000-0000-0000-000000000000", now: now)) { error in
            guard case .wrongDevice(let licensed, let thisMac) = error as? OwnerLicenseError else { return XCTFail("\(error)") }
            XCTAssertEqual(licensed, Self.device)
            XCTAssertEqual(thisMac, "FFFFFFFF-0000-0000-0000-000000000000")
        }
    }

    func testExpiryIsEnforcedAtTheBoundary() throws {
        let license = try verifier.verify(Self.data(Self.expiring), deviceID: Self.device, now: now)
        XCTAssertEqual(license.expiresAtDate, ISO8601DateParser.parse("2026-10-01T00:00:00Z"))
        let atExpiry = ISO8601DateParser.parse("2026-10-01T00:00:00Z")!
        XCTAssertThrowsError(try verifier.verify(Self.data(Self.expiring), deviceID: Self.device, now: atExpiry)) { error in
            guard case .expired = error as? OwnerLicenseError else { return XCTFail("\(error)") }
        }
    }

    func testTamperedPayloadAndForeignKeyAreRefused() throws {
        var payload = try XCTUnwrap(String(data: Data(base64Encoded: Self.open.payload)!, encoding: .utf8))
        payload = payload.replacingOccurrences(of: "owner@example.com", with: "thief@example.com")
        let tampered = OwnerLicenseEnvelope(payload: Data(payload.utf8).base64EncodedString(), signature: Self.open.signature)
        XCTAssertThrowsError(try verifier.verify(Self.data(tampered), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .badSignature)
        }
        let foreign = OwnerLicenseVerifier(publicKeyBase64: Self.otherPublicKey)
        XCTAssertThrowsError(try foreign.verify(Self.data(Self.open), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .badSignature)
        }
    }

    func testMalformedInputsAndAMissingKeyAreDistinguished() throws {
        XCTAssertThrowsError(try verifier.verify(Data("not json".utf8), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .malformed)
        }
        let shortSignature = OwnerLicenseEnvelope(payload: Self.open.payload, signature: Data([1, 2, 3]).base64EncodedString())
        XCTAssertThrowsError(try verifier.verify(Self.data(shortSignature), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .malformed)
        }
        let unconfigured = OwnerLicenseVerifier(publicKeyBase64: "OWNER_PUBLIC_KEY_PLACEHOLDER")
        XCTAssertThrowsError(try unconfigured.verify(Self.data(Self.open), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .keyMissing)
        }
    }

    func testUnparseableExpiryIsMalformedNotUnlimited() throws {
        XCTAssertThrowsError(try verifier.verify(Self.data(Self.badExpiry), deviceID: Self.device, now: now)) { error in
            XCTAssertEqual(error as? OwnerLicenseError, .malformed)
        }
    }

    func testTheShippedPublicKeyIsARealKey() {
        XCTAssertTrue(OwnerLicensePublicKey.isConfigured, "release builds must carry the owner's public key")
        XCTAssertNotEqual(OwnerLicensePublicKey.base64, Self.publicKey, "the test vector key must never be the shipped key")
    }

    func testAccessSnapshotIsAnActiveAdminBoundToTheLicense() throws {
        let license = try verifier.verify(Self.data(Self.open), deviceID: Self.device, now: now)
        let snapshot = license.accessSnapshot(now: now)
        XCTAssertTrue(snapshot.entitlement.active)
        XCTAssertEqual(snapshot.entitlement.source, .admin)
        XCTAssertTrue(snapshot.user.isAdmin)
        XCTAssertTrue(snapshot.user.isOwnerLicenseAccount)
        XCTAssertEqual(snapshot.user.email, "owner@example.com")
        XCTAssertEqual(snapshot.entitlement.graceUntilDate, now.addingTimeInterval(OwnerLicense.snapshotHorizon))
        let expiring = try verifier.verify(Self.data(Self.expiring), deviceID: Self.device, now: now)
        XCTAssertEqual(expiring.accessSnapshot(now: now).entitlement.expiresAtDate, expiring.expiresAtDate)
    }
}
