import CryptoKit
import Foundation

/// Checks an owner license file against the embedded Ed25519 public key,
/// this Mac's identifier, and the clock. Pure: the caller supplies the
/// bytes, the device id, and the time, so every branch is unit testable.
/// Mirrors OwnerLicenseSigner.verify in server/src/owner.
struct OwnerLicenseVerifier {
    static let signatureLength = 64
    static let publicKeyLength = 32

    let publicKeyBase64: String

    init(publicKeyBase64: String = OwnerLicensePublicKey.base64) {
        self.publicKeyBase64 = publicKeyBase64
    }

    func verify(_ envelopeData: Data, deviceID: String, now: Date) throws -> OwnerLicense {
        guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == OwnerLicenseVerifier.publicKeyLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw OwnerLicenseError.keyMissing
        }
        guard let envelope = try? JSONDecoder().decode(OwnerLicenseEnvelope.self, from: envelopeData),
              let payload = Data(base64Encoded: envelope.payload), !payload.isEmpty,
              let signature = Data(base64Encoded: envelope.signature), signature.count == OwnerLicenseVerifier.signatureLength else {
            throw OwnerLicenseError.malformed
        }
        guard key.isValidSignature(signature, for: payload) else {
            throw OwnerLicenseError.badSignature
        }
        guard let license = try? JSONDecoder().decode(OwnerLicense.self, from: payload) else {
            throw OwnerLicenseError.malformed
        }
        guard license.version == OwnerLicense.currentVersion else {
            throw OwnerLicenseError.unsupportedVersion(license.version)
        }
        guard license.issuedAtDate != nil, license.expiresAt == nil || license.expiresAtDate != nil else {
            throw OwnerLicenseError.malformed
        }
        let thisMac = OwnerLicenseVerifier.normalizedDeviceID(deviceID)
        let licensed = OwnerLicenseVerifier.normalizedDeviceID(license.deviceID)
        guard licensed == thisMac else {
            throw OwnerLicenseError.wrongDevice(licensed: licensed, thisMac: thisMac)
        }
        if let expiry = license.expiresAtDate, expiry <= now {
            throw OwnerLicenseError.expired(expiry)
        }
        return license
    }

    /// IOPlatformUUID as the signer writes it: trimmed and upper case.
    static func normalizedDeviceID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
