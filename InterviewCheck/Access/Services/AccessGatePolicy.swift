import Foundation

/// What the app is allowed to do right now, and why.
enum AccessGateState: Equatable {
    case checking
    case signedOut
    case allowed(AccessSnapshot, offline: Bool)
    case paywall(AccessSnapshot)
    case unreachable(message: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var snapshot: AccessSnapshot? {
        switch self {
        case .allowed(let snapshot, _), .paywall(let snapshot): return snapshot
        case .checking, .signedOut, .unreachable: return nil
        }
    }
}

/// Pure decision: combines the token presence, the latest server answer,
/// the cached snapshot, and an owner license into one gate state. The
/// server is the source of truth for accounts; the cache only bridges
/// connectivity gaps inside `graceUntil`; a valid owner license is a floor
/// that keeps the owner's Mac unlocked whatever the server says or whether
/// it can be reached at all.
enum AccessGatePolicy {
    struct Input {
        var hasToken: Bool
        var fresh: Result<AccessSnapshot, AccessAPIError>?
        var cached: CachedAccessSnapshot?
        var now: Date
        var ownerLicense: OwnerLicense? = nil
    }

    static func decide(_ input: Input) -> AccessGateState {
        let server = decideFromServer(input)
        if server.isAllowed { return server }
        if let license = input.ownerLicense {
            return .allowed(license.accessSnapshot(now: input.now), offline: false)
        }
        return server
    }

    private static func decideFromServer(_ input: Input) -> AccessGateState {
        guard input.hasToken else { return .signedOut }
        guard let fresh = input.fresh else { return .checking }

        switch fresh {
        case .success(let snapshot):
            return snapshot.entitlement.active ? .allowed(snapshot, offline: false) : .paywall(snapshot)
        case .failure(let error):
            if error.invalidatesSession { return .signedOut }
            if let cached = input.cached {
                // A clock set back past the fetch time cannot extend grace.
                if input.now < cached.fetchedAt { return .unreachable(message: error.localizedDescription) }
                let graceUntil = cached.snapshot.entitlement.graceUntilDate ?? cached.fetchedAt
                if cached.snapshot.entitlement.active, input.now < graceUntil {
                    return .allowed(cached.snapshot, offline: true)
                }
                if !cached.snapshot.entitlement.active {
                    return .paywall(cached.snapshot)
                }
            }
            return .unreachable(message: error.localizedDescription)
        }
    }
}
