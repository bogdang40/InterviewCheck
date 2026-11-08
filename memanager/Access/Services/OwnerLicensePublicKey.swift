import Foundation

/// The owner's Ed25519 public key (raw 32 bytes, base64). The matching
/// private key lives only with the owner, outside the repository
/// (default ~/.interviewcheck/owner-signing.key). Regenerating the key pair
/// invalidates every license issued so far, so treat this constant as
/// part of the app's identity, not as configuration.
enum OwnerLicensePublicKey {
    static let base64 = "XOzLg8hhgMzBLd28UzAIaHruaj/JPBMqpXtv5D1Qj64="

    static var isConfigured: Bool {
        Data(base64Encoded: base64)?.count == OwnerLicenseVerifier.publicKeyLength
    }
}
