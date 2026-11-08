import Foundation

/// Pure copy for the Account page rows.
enum AccountPresentation {
    static func roleDescription(_ user: AccountUser) -> String {
        user.isAdmin ? "Admin" : "Member"
    }

    static func accessDescription(_ snapshot: AccessSnapshot) -> String {
        let entitlement = snapshot.entitlement
        guard entitlement.active else { return "Inactive" }
        if snapshot.user.isOwnerLicenseAccount { return "Owner license, bound to this Mac" }
        var text = entitlement.source.displayName
        if let expires = entitlement.expiresAtDate {
            text += ", until \(dateString(expires))"
        }
        return text
    }

    static func subscriptionDescription(_ subscription: AccountSubscription) -> String {
        var parts = [subscription.plan?.capitalized ?? "Plan", subscription.status.replacingOccurrences(of: "_", with: " ")]
        if subscription.cancelAtPeriodEnd { parts.append("cancels at period end") }
        if let end = subscription.currentPeriodEndDate {
            parts.append("\(subscription.cancelAtPeriodEnd ? "ends" : "current period ends") \(dateString(end))")
        }
        return parts.joined(separator: ", ")
    }

    static func stateDescription(_ state: AccessGateState) -> String {
        switch state {
        case .checking: return "Checking your account"
        case .signedOut: return "Not signed in"
        case .unreachable(let message): return "Server unreachable: \(message)"
        case .allowed, .paywall: return ""
        }
    }

    /// Badge for the status row when there is no snapshot to describe.
    static func stateBadge(_ state: AccessGateState) -> (text: String, tone: OverlayTone) {
        switch state {
        case .checking: return ("Checking", .info)
        case .signedOut: return ("Signed out", .neutral)
        case .unreachable: return ("Unreachable", .warning)
        case .allowed: return ("Signed in", .success)
        case .paywall: return ("No plan", .warning)
        }
    }

    /// The offline notice, or nil when the grant in force is fresh or the
    /// owner license is doing the unlocking.
    static func offlineNotice(state: AccessGateState, ownerLicense: OwnerLicenseResolution) -> String? {
        guard case .allowed(let snapshot, let offline) = state, offline, ownerLicense.license == nil else { return nil }
        let until = snapshot.entitlement.graceUntilDate.map(dateString) ?? "soon"
        return "Offline: using the last verified entitlement until \(until)."
    }

    static func serverAccountHint(isUnlockedByOwnerLicense: Bool) -> String {
        isUnlockedByOwnerLicense
            ? "The owner license unlocks this Mac. Sign in to the access server only to manage other accounts."
            : "Sign in to the access server."
    }

    static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
