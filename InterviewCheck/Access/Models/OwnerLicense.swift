import Foundation

/// A signed grant that unlocks InterviewCheck on one Mac with no server in the
/// loop. Issued by the owner's private key (server/src/tools/owner-license.ts);
/// the app only carries the public key, so nobody else can mint one, and the
/// device binding means a copied file is worthless elsewhere.
struct OwnerLicense: Codable, Equatable {
    static let currentVersion = 1
    /// How far ahead the synthesized entitlement claims to be valid when the
    /// license itself carries no expiry. Re-derived on every evaluation.
    static let snapshotHorizon: TimeInterval = 365 * 86_400
    static let accountIDPrefix = "owner:"

    let version: Int
    let email: String
    let deviceID: String
    let issuedAt: String
    let expiresAt: String?
    let note: String?

    var issuedAtDate: Date? { ISO8601DateParser.parse(issuedAt) }
    var expiresAtDate: Date? { expiresAt.flatMap(ISO8601DateParser.parse) }
    var accountID: String { OwnerLicense.accountIDPrefix + deviceID }

    /// The account state the app runs with when the license is the grant in
    /// force: an admin with an active entitlement, mirroring what the server
    /// would answer for the owner.
    func accessSnapshot(now: Date) -> AccessSnapshot {
        let horizon = expiresAt ?? ISO8601DateParser.string(from: now.addingTimeInterval(OwnerLicense.snapshotHorizon))
        return AccessSnapshot(
            user: AccountUser(id: accountID, email: email, role: .admin, disabled: false, createdAt: issuedAt, trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: true, source: .admin, expiresAt: expiresAt, graceUntil: horizon, plan: nil, subscriptionStatus: nil),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }
}

extension AccountUser {
    /// True for the synthesized owner account, which has no server record.
    var isOwnerLicenseAccount: Bool { id.hasPrefix(OwnerLicense.accountIDPrefix) }
}

/// What is stored on disk: the exact payload bytes that were signed, plus
/// the signature, both base64.
struct OwnerLicenseEnvelope: Codable, Equatable {
    let payload: String
    let signature: String
}

enum OwnerLicenseError: Error, LocalizedError, Equatable {
    case keyMissing
    case malformed
    case badSignature
    case unsupportedVersion(Int)
    case wrongDevice(licensed: String, thisMac: String)
    case expired(Date)
    case deviceUnavailable

    var errorDescription: String? {
        switch self {
        case .keyMissing:
            return "This build carries no owner public key, so no license can be checked."
        case .malformed:
            return "The file is not an owner license."
        case .badSignature:
            return "The license signature does not match this app's owner key."
        case .unsupportedVersion(let version):
            return "License version \(version) is newer than this app understands."
        case .wrongDevice(let licensed, let thisMac):
            return "The license is bound to Mac \(licensed), but this Mac is \(thisMac)."
        case .expired(let date):
            return "The license expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .deviceUnavailable:
            return "This Mac's hardware identifier could not be read."
        }
    }
}

/// Whether a license is present on this Mac and what the verifier made of it.
enum OwnerLicenseResolution: Equatable {
    case none
    case valid(OwnerLicense)
    case invalid(OwnerLicenseError)

    var license: OwnerLicense? {
        if case .valid(let license) = self { return license }
        return nil
    }
}
