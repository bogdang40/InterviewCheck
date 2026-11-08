import Foundation

/// Admin API payloads. Kept apart from the account models so the regular
/// client never depends on them.
struct AdminUserView: Codable, Equatable, Identifiable {
    let user: AccountUser
    let entitlement: Entitlement
    let subscription: AccountSubscription?
    let lastLoginAt: String?

    var id: String { user.id }
}

struct AdminUserPage: Codable, Equatable {
    let users: [AdminUserView]
    let nextCursor: String?
}

struct AdminStats: Codable, Equatable {
    let totalUsers: Int
    let admins: Int
    let liveSubscriptions: Int
}

/// PATCH /v1/admin/users/:id. Optional fields are omitted; a null
/// complimentaryUntil clears the grant, which needs explicit null encoding.
struct AdminUserPatch: Equatable {
    var role: AccountRole?
    var disabled: Bool?
    var complimentaryUntil: Date??

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let role { object["role"] = role.rawValue }
        if let disabled { object["disabled"] = disabled }
        if let complimentaryUntil {
            object["complimentaryUntil"] = complimentaryUntil.map(ISO8601DateParser.string(from:)) ?? NSNull()
        }
        return object
    }
}

struct AdminAuditEntry: Codable, Equatable, Identifiable {
    let id: Int
    let at: String
    let actorUserId: String?
    let action: String
    let targetUserId: String?
}

struct AdminAuditPage: Codable, Equatable {
    let entries: [AdminAuditEntry]
}
