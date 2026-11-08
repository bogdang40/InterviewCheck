import XCTest
@testable import InterviewCheck

final class AccessPresentationTests: XCTestCase {
    private func user(role: AccountRole = .user, trialEndsAt: String? = nil, complimentaryUntil: String? = nil) -> AccountUser {
        AccountUser(id: "u1", email: "abe@example.com", role: role, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: trialEndsAt, complimentaryUntil: complimentaryUntil)
    }

    private func entitlement(active: Bool, source: EntitlementSource, expiresAt: String? = nil) -> Entitlement {
        Entitlement(active: active, source: source, expiresAt: expiresAt, graceUntil: "2026-02-01T00:00:00Z", plan: nil, subscriptionStatus: nil)
    }

    // MARK: Paywall

    func testPaywallStatusExplainsWhyAccessIsBlocked() {
        let now = ISO8601DateParser.parse("2026-03-01T00:00:00Z")!
        let expiredTrial = AccessSnapshot(user: user(trialEndsAt: "2026-02-01T00:00:00Z"), entitlement: entitlement(active: false, source: .none), subscription: nil, serverTime: "")
        XCTAssertEqual(PaywallPresentation.statusLine(for: expiredTrial, now: now), "Your trial has ended. Subscribe to keep using InterviewCheck.")

        let lapsed = AccessSnapshot(user: user(), entitlement: entitlement(active: false, source: .none), subscription: AccountSubscription(id: "s", status: "past_due", plan: "monthly", currentPeriodEnd: nil, cancelAtPeriodEnd: false), serverTime: "")
        XCTAssertEqual(PaywallPresentation.statusLine(for: lapsed, now: now), "Your subscription is past due. Renew to continue.")

        let fresh = AccessSnapshot(user: user(), entitlement: entitlement(active: false, source: .none), subscription: nil, serverTime: "")
        XCTAssertEqual(PaywallPresentation.statusLine(for: fresh, now: now), "Your account has no active plan yet.")

        let expiredGrant = AccessSnapshot(user: user(), entitlement: entitlement(active: false, source: .complimentary), subscription: nil, serverTime: "")
        XCTAssertEqual(PaywallPresentation.statusLine(for: expiredGrant, now: now), "Your complimentary access has expired.")
    }

    func testPaywallPlanNamingAndDefaultSelection() {
        XCTAssertEqual(PaywallPresentation.planTitle("annual"), "Annual")
        XCTAssertEqual(PaywallPresentation.planTitle("team"), "Team")
        // The API returns identifiers, not prices or savings. Preserve its order
        // without assigning an unsupported value recommendation.
        XCTAssertFalse(PaywallPresentation.isRecommended("annual"))
        XCTAssertFalse(PaywallPresentation.isRecommended("monthly"))
        XCTAssertEqual(PaywallPresentation.planCaption("annual"), "Price and terms shown at checkout.")
        XCTAssertEqual(PaywallPresentation.planCaption("monthly"), "Price and terms shown at checkout.")
        XCTAssertEqual(PaywallPresentation.defaultSelection(in: ["monthly", "annual"]), "monthly")
        XCTAssertEqual(PaywallPresentation.defaultSelection(in: ["annual", "monthly"]), "annual")
        XCTAssertEqual(PaywallPresentation.defaultSelection(in: ["monthly"]), "monthly")
        XCTAssertNil(PaywallPresentation.defaultSelection(in: []))
    }

    // MARK: Account

    func testAccountDescriptions() {
        let inactive = AccessSnapshot(user: user(), entitlement: entitlement(active: false, source: .none), subscription: nil, serverTime: "")
        XCTAssertEqual(AccountPresentation.accessDescription(inactive), "Inactive")

        let subscribed = AccessSnapshot(user: user(), entitlement: entitlement(active: true, source: .subscription), subscription: nil, serverTime: "")
        XCTAssertEqual(AccountPresentation.accessDescription(subscribed), "Subscription")

        let owner = AccountSnapshotFactory.owner()
        XCTAssertEqual(AccountPresentation.accessDescription(owner), "Owner license, bound to this Mac")
        XCTAssertEqual(AccountPresentation.roleDescription(owner.user), "Admin")

        let subscription = AccountSubscription(id: "s", status: "past_due", plan: "annual", currentPeriodEnd: nil, cancelAtPeriodEnd: true)
        XCTAssertEqual(AccountPresentation.subscriptionDescription(subscription), "Annual, past due, cancels at period end")
        XCTAssertEqual(AccountPresentation.stateDescription(.signedOut), "Not signed in")
        XCTAssertEqual(AccountPresentation.stateDescription(.unreachable(message: "timeout")), "Server unreachable: timeout")
        XCTAssertEqual(AccountPresentation.stateBadge(.checking).text, "Checking")
        XCTAssertEqual(AccountPresentation.stateBadge(.checking).tone, .info)
        XCTAssertEqual(AccountPresentation.stateBadge(.unreachable(message: "x")).tone, .warning)
        XCTAssertEqual(AccountPresentation.stateBadge(.signedOut).text, "Signed out")
    }

    func testOfflineNoticeOnlyWhenOfflineWithoutOwnerLicense() {
        let snapshot = AccessSnapshot(user: user(), entitlement: entitlement(active: true, source: .subscription), subscription: nil, serverTime: "")
        XCTAssertNil(AccountPresentation.offlineNotice(state: .allowed(snapshot, offline: false), ownerLicense: .none))
        XCTAssertNotNil(AccountPresentation.offlineNotice(state: .allowed(snapshot, offline: true), ownerLicense: .none))
        let license = OwnerLicense(version: 1, email: "o@example.com", deviceID: "d", issuedAt: "2026-01-01T00:00:00Z", expiresAt: nil, note: nil)
        XCTAssertNil(AccountPresentation.offlineNotice(state: .allowed(snapshot, offline: true), ownerLicense: .valid(license)))
    }

    // MARK: Admin rows

    func testAdminRowDetailAndBadge() {
        let never = AdminUserView(user: user(), entitlement: entitlement(active: false, source: .none), subscription: nil, lastLoginAt: nil)
        XCTAssertEqual(AdminUserRowPresentation.detailLine(for: never), "never signed in")
        XCTAssertEqual(AdminUserRowPresentation.entitlementBadge(for: never).text, "No access")
        XCTAssertEqual(AdminUserRowPresentation.entitlementBadge(for: never).tone, .warning)

        let subscribed = AdminUserView(user: user(), entitlement: entitlement(active: true, source: .subscription), subscription: AccountSubscription(id: "s", status: "active", plan: "monthly", currentPeriodEnd: nil, cancelAtPeriodEnd: false), lastLoginAt: nil)
        XCTAssertEqual(AdminUserRowPresentation.detailLine(for: subscribed), "monthly active")
        XCTAssertEqual(AdminUserRowPresentation.entitlementBadge(for: subscribed).text, "Subscription")
        XCTAssertEqual(AdminUserRowPresentation.entitlementBadge(for: subscribed).tone, .success)
    }
}

private enum AccountSnapshotFactory {
    static func owner() -> AccessSnapshot {
        OwnerLicense(version: 1, email: "o@example.com", deviceID: "device", issuedAt: "2026-01-01T00:00:00Z", expiresAt: nil, note: nil)
            .accessSnapshot(now: Date())
    }
}
