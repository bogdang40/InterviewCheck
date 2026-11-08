import Foundation

/// Pure copy and tones for one admin list row.
enum AdminUserRowPresentation {
    static func detailLine(for view: AdminUserView, now: Date = Date()) -> String {
        var parts: [String] = []
        if let subscription = view.subscription {
            parts.append("\(subscription.plan ?? "plan") \(subscription.status)")
        }
        if let until = view.user.complimentaryUntil.flatMap(ISO8601DateParser.parse) {
            parts.append("complimentary until \(until.formatted(date: .abbreviated, time: .omitted))")
        }
        if let last = view.lastLoginAt.flatMap(ISO8601DateParser.parse) {
            parts.append("last login \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.isEmpty ? "never signed in" : parts.joined(separator: ", ")
    }

    static func entitlementBadge(for view: AdminUserView) -> (text: String, tone: OverlayTone) {
        view.entitlement.active
            ? (view.entitlement.source.displayName, .success)
            : ("No access", .warning)
    }
}
