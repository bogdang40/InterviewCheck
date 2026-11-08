import CryptoKit
import XCTest
@testable import memanager

final class AccessGatePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func snapshot(active: Bool, graceOffset: TimeInterval = 7 * 86_400, role: AccountRole = .user) -> AccessSnapshot {
        AccessSnapshot(
            user: AccountUser(id: "u1", email: "a@b.c", role: role, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil, graceUntil: ISO8601DateParser.string(from: now.addingTimeInterval(graceOffset)), plan: nil, subscriptionStatus: nil),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }

    func testNoTokenMeansSignedOutRegardlessOfCache() {
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true), fetchedAt: now)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: false, fresh: nil, cached: cached, now: now)), .signedOut)
    }

    func testFreshActiveAllowsAndFreshInactivePaywalls() {
        let active = snapshot(active: true)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .success(active), cached: nil, now: now)), .allowed(active, offline: false))
        let inactive = snapshot(active: false)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .success(inactive), cached: nil, now: now)), .paywall(inactive))
    }

    func testInvalidSessionSignsOutEvenWithCache() {
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true), fetchedAt: now)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(.unauthenticated), cached: cached, now: now)), .signedOut)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(.server(status: 401, code: "session_invalid", message: "x")), cached: cached, now: now)), .signedOut)
    }

    func testOfflineInsideGraceUsesCacheAndOutsideGraceDoesNot() {
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true, graceOffset: 3_600), fetchedAt: now)
        let offline = AccessAPIError.network("down")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(offline), cached: cached, now: now)), .allowed(cached.snapshot, offline: true))
        let later = now.addingTimeInterval(7_200)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(offline), cached: cached, now: later)), .unreachable(message: offline.localizedDescription))
    }

    func testClockSetBackBeforeTheFetchCannotExtendGrace() {
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true, graceOffset: 30 * 86_400), fetchedAt: now)
        let earlier = now.addingTimeInterval(-3_600)
        let offline = AccessAPIError.network("down")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(offline), cached: cached, now: earlier)), .unreachable(message: offline.localizedDescription))
    }

    func testBareServer401DoesNotInvalidateButServerCodesDo() {
        XCTAssertFalse(AccessAPIError.server(status: 401, code: "http_401", message: "x").invalidatesSession)
        XCTAssertTrue(AccessAPIError.server(status: 401, code: "session_invalid", message: "x").invalidatesSession)
        XCTAssertTrue(AccessAPIError.server(status: 401, code: "unauthenticated", message: "x").invalidatesSession)
        XCTAssertFalse(AccessAPIError.server(status: 403, code: "session_invalid", message: "x").invalidatesSession)
    }

    func testSignInFormRules() {
        XCTAssertTrue(SignInFormRules.canSubmit(email: "a@b.c", password: "0123456789", confirmPassword: "", isCreatingAccount: false, isBusy: false))
        XCTAssertFalse(SignInFormRules.canSubmit(email: "a@b.c", password: "short", confirmPassword: "", isCreatingAccount: false, isBusy: false))
        XCTAssertFalse(SignInFormRules.canSubmit(email: "nope", password: "0123456789", confirmPassword: "", isCreatingAccount: false, isBusy: false))
        XCTAssertFalse(SignInFormRules.canSubmit(email: "a@b.c", password: "0123456789", confirmPassword: "0123456780", isCreatingAccount: true, isBusy: false))
        XCTAssertTrue(SignInFormRules.canSubmit(email: " a@b.c ", password: "0123456789", confirmPassword: "0123456789", isCreatingAccount: true, isBusy: false))
        XCTAssertFalse(SignInFormRules.canSubmit(email: "a@b.c", password: "0123456789", confirmPassword: "", isCreatingAccount: false, isBusy: true))
    }

    func testOfflineWithInactiveCacheShowsPaywall() {
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: false), fetchedAt: now)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(.network("down")), cached: cached, now: now)), .paywall(cached.snapshot))
    }

    func testPendingFetchIsChecking() {
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: nil, cached: nil, now: now)), .checking)
    }

    func testOwnerLicenseIsAFloorUnderTheServerDecision() {
        let license = OwnerLicense(version: 1, email: "owner@example.com", deviceID: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", issuedAt: ISO8601DateParser.string(from: now), expiresAt: nil, note: nil)
        let licensed = AccessGateState.allowed(license.accessSnapshot(now: now), offline: false)

        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: false, fresh: nil, cached: nil, now: now, ownerLicense: license)), licensed, "no account at all")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: nil, cached: nil, now: now, ownerLicense: license)), licensed, "still checking the server")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(.network("down")), cached: nil, now: now, ownerLicense: license)), licensed, "server unreachable")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .failure(.unauthenticated), cached: nil, now: now, ownerLicense: license)), licensed, "server session invalid")
        let inactive = snapshot(active: false)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .success(inactive), cached: nil, now: now, ownerLicense: license)), licensed, "paywalled account")

        let active = snapshot(active: true)
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: true, fresh: .success(active), cached: nil, now: now, ownerLicense: license)), .allowed(active, offline: false), "a live server grant is the one reported")
        XCTAssertEqual(AccessGatePolicy.decide(.init(hasToken: false, fresh: nil, cached: nil, now: now)), .signedOut, "no license, no change")
    }

    func testDeepLinkParsing() {
        XCTAssertEqual(AccessDeepLink.parse(URL(string: "memanager://billing/success")!), .billingSuccess)
        XCTAssertEqual(AccessDeepLink.parse(URL(string: "MEMANAGER://Billing/Cancel/")!), .billingCancel)
        XCTAssertEqual(AccessDeepLink.parse(URL(string: "memanager://billing/portal")!), .billingPortal)
        XCTAssertNil(AccessDeepLink.parse(URL(string: "memanager://other/success")!))
        XCTAssertNil(AccessDeepLink.parse(URL(string: "https://example.com/billing/success")!))
    }

    func testServerAddressNormalization() throws {
        XCTAssertEqual(try AccessServerAddress.url(from: "access.example.com/").absoluteString, "https://access.example.com")
        XCTAssertEqual(try AccessServerAddress.url(from: " http://localhost:8787// ").absoluteString, "http://localhost:8787")
        XCTAssertEqual(try AccessServerAddress.url(from: "http://127.0.0.1:8787").host, "127.0.0.1")
        XCTAssertThrowsError(try AccessServerAddress.url(from: ""))
        XCTAssertThrowsError(try AccessServerAddress.url(from: "ftp://nope"))
        XCTAssertThrowsError(try AccessServerAddress.url(from: "http://access.example.com"), "clear text to a real host is refused")
    }

    func testReleaseBuildsAcceptOnlyLoopbackOverrides() {
        XCTAssertEqual(AccessServerAddress.resolve(stored: "https://evil.example.com", editable: true), "https://evil.example.com", "debug builds trust the setting")
        XCTAssertEqual(AccessServerAddress.resolve(stored: "https://evil.example.com", editable: false), AccessServerAddress.releaseOrigin)
        XCTAssertEqual(AccessServerAddress.resolve(stored: "http://localhost:8787", editable: false), "http://localhost:8787")
        XCTAssertEqual(AccessServerAddress.resolve(stored: "http://127.0.0.1:9999", editable: false), "http://127.0.0.1:9999")
        XCTAssertEqual(AccessServerAddress.resolve(stored: "not a url", editable: false), AccessServerAddress.releaseOrigin)
    }

    func testSignedSnapshotCacheRejectsTamperedPayloads() {
        let suiteName = "access-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SymmetricKey(size: .bits256)
        let cache = UserDefaultsAccessSnapshotCache(defaults: defaults, macKeyProvider: { key })
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true), fetchedAt: now)
        cache.save(cached)
        XCTAssertEqual(cache.load(), cached)

        // Flip one byte of the stored envelope's payload: the MAC no longer verifies.
        var raw = defaults.data(forKey: UserDefaultsAccessSnapshotCache.key)!
        if let range = raw.range(of: Data("true".utf8)) {
            raw.replaceSubrange(range, with: Data("tru1".utf8))
        } else {
            raw[raw.count / 2] ^= 0x01
        }
        defaults.set(raw, forKey: UserDefaultsAccessSnapshotCache.key)
        XCTAssertNil(cache.load())

        // A different key also fails.
        cache.save(cached)
        XCTAssertNil(UserDefaultsAccessSnapshotCache(defaults: defaults, macKeyProvider: { SymmetricKey(size: .bits256) }).load())
    }

    func testAdminPatchEncodesNullToClearGrant() throws {
        let clear = AdminUserPatch(complimentaryUntil: .some(nil)).jsonObject()
        XCTAssertTrue(clear["complimentaryUntil"] is NSNull)
        let omitted = AdminUserPatch(role: .admin).jsonObject()
        XCTAssertNil(omitted["complimentaryUntil"])
        XCTAssertEqual(omitted["role"] as? String, "admin")
        let dated = AdminUserPatch(complimentaryUntil: .some(now)).jsonObject()
        XCTAssertEqual(dated["complimentaryUntil"] as? String, ISO8601DateParser.string(from: now))
    }
}
