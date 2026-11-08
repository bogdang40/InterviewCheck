import Foundation

/// Pure copy for the paywall: why the account is blocked and how each plan
/// is named.
enum PaywallPresentation {
    static func statusLine(for snapshot: AccessSnapshot, now: Date = Date()) -> String {
        switch snapshot.entitlement.source {
        case .none:
            if let trial = snapshot.user.trialEndsAt, let date = ISO8601DateParser.parse(trial), date < now {
                return "Your trial has ended. Subscribe to keep using \(AppBrand.name)."
            }
            if let status = snapshot.subscription?.status, status != "active" {
                return "Your subscription is \(status.replacingOccurrences(of: "_", with: " ")). Renew to continue."
            }
            return "Your account has no active plan yet."
        default:
            return "Your \(snapshot.entitlement.source.displayName.lowercased()) has expired."
        }
    }

    static func planTitle(_ plan: String) -> String {
        switch plan {
        case "annual": return "Annual"
        case "monthly": return "Monthly"
        default: return plan.capitalized
        }
    }

    static func planCaption(_ plan: String) -> String {
        "Price and terms shown at checkout."
    }

    static func isRecommended(_ plan: String) -> Bool {
        false
    }

    /// The plan to preselect: the recommended one when offered, else the first.
    static func defaultSelection(in plans: [String]) -> String? {
        plans.first
    }
}
