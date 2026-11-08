import Foundation

/// Wire types shared with the access server. Field names match the JSON the
/// server emits, so decoding uses default keys.
enum AccountRole: String, Codable, Equatable {
    case user
    case admin
}

struct AccountUser: Codable, Equatable, Identifiable {
    let id: String
    let email: String
    let role: AccountRole
    let disabled: Bool
    let createdAt: String
    let trialEndsAt: String?
    let complimentaryUntil: String?

    var isAdmin: Bool { role == .admin }
}

enum EntitlementSource: String, Codable, Equatable {
    case admin
    case subscription
    case complimentary
    case trial
    case none

    var displayName: String {
        switch self {
        case .admin: return "Admin"
        case .subscription: return "Subscription"
        case .complimentary: return "Complimentary access"
        case .trial: return "Trial"
        case .none: return "No access"
        }
    }
}

struct Entitlement: Codable, Equatable {
    let active: Bool
    let source: EntitlementSource
    let expiresAt: String?
    let graceUntil: String
    let plan: String?
    let subscriptionStatus: String?

    var expiresAtDate: Date? { expiresAt.flatMap(ISO8601DateParser.parse) }
    var graceUntilDate: Date? { ISO8601DateParser.parse(graceUntil) }
}

struct AccountSubscription: Codable, Equatable {
    let id: String
    let status: String
    let plan: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool

    var currentPeriodEndDate: Date? { currentPeriodEnd.flatMap(ISO8601DateParser.parse) }
}

/// GET /v1/me and the body of signup and login (plus the token there).
struct AccessSnapshot: Codable, Equatable {
    let user: AccountUser
    let entitlement: Entitlement
    let subscription: AccountSubscription?
    let serverTime: String
}

struct SignedInResponse: Codable, Equatable {
    let token: String
    let user: AccountUser
    let entitlement: Entitlement
    let subscription: AccountSubscription?
    let serverTime: String

    var snapshot: AccessSnapshot {
        AccessSnapshot(user: user, entitlement: entitlement, subscription: subscription, serverTime: serverTime)
    }
}

struct BillingPlans: Codable, Equatable {
    let configured: Bool
    let plans: [String]
}

struct RedirectURLResponse: Codable, Equatable {
    let url: String
}

struct AccessErrorBody: Codable, Equatable {
    struct Payload: Codable, Equatable {
        let code: String
        let message: String
    }
    let error: Payload
}

/// Server timestamps carry fractional seconds; Foundation's default ISO8601
/// formatter rejects them, so parsing tries both shapes.
enum ISO8601DateParser {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        withFractional.date(from: value) ?? plain.date(from: value)
    }

    static func string(from date: Date) -> String {
        withFractional.string(from: date)
    }
}
