# Accounts, Subscriptions, and Admin

InterviewCheck is sold as a subscription. The macOS app cannot hold a Stripe
secret or decide its own entitlement, so a small server in `server/` is the
source of truth and the app is a client of it.

## Architecture

```
macOS app                              server/ (Node 22, Hono, node:sqlite)
AccessController  --- /v1/me --------> EntitlementService -> EntitlementResolver
SignInView        --- /v1/auth/* ----> AuthService (scrypt, opaque tokens)
PaywallView       --- /v1/billing/* -> BillingService -> Stripe Checkout / Portal
AdminPanelView    --- /v1/admin/* ---> AdminService (role, grants, disable)
                                       Stripe webhook -> subscriptions table
```

Admin privilege is a column on the server's `users` table. A signup claims
it only when the email is in `ADMIN_EMAILS` and the request carries the
`ADMIN_BOOTSTRAP_SECRET` (entered under Advanced in the create account form).
Any admin can then promote or demote others from the in app Admin tab.
Admins always have access regardless of subscription state.

## Launch gate

`AppDelegate.applicationDidFinishLaunching` evaluates `AccessController`,
then builds the overlay and hotkeys unconditionally. The gate is not a
separate window: `MentorView` renders `AccessGateView` in place of the shell
while the account is not entitled, so sign in shares the stealth overlay's
look and its screen capture protection. The overlay is brought to the front
whenever the gate applies; otherwise it starts hidden as before.

- token missing: sign in screen
- entitlement inactive: paywall screen
- server unreachable with a cached active entitlement inside `graceUntil`:
  allowed offline
- otherwise: unreachable screen with retry and server address

`AccessGatePolicy.decide` is the pure function behind this and is fully unit
tested. When the periodic check (every six hours) finds access revoked, the
overlay comes back up showing the gate. Escape does not hide the overlay
while the gate is up (an LSUIElement app with no hotkeys would have no way
back); Cmd+D toggles it and Cmd+E quits, and the gate footer says so.
`SessionController.solve`, `solveSystemDesign`, and `quickAssist` refuse to
run without access through `AccessGuard`.

An evaluation that was in flight when the user signed out discards its
result (`sessionGeneration` in `AccessController`), so a late `/me` answer
cannot revive the cleared cache or flip the sign in screen to a stale state.

## Owner license (no server needed)

The owner should never depend on a running server to use the app. An
owner license is a small signed file bound to one Mac:

- `server/src/owner/OwnerLicenseSigner.ts` signs `{version, email,
  deviceID, issuedAt, expiresAt, note}` with an Ed25519 private key. The
  key pair is created once with `npm run owner-license -- keygen`; the
  private key lives in `~/.InterviewCheck/owner-signing.key` (mode 600, never
  in the repository) and the public key is compiled into the app as
  `OwnerLicensePublicKey.base64`. Regenerating the key invalidates every
  license issued so far.
- `npm run owner-license -- issue --email you@example.com --device auto`
  reads this Mac's IOPlatformUUID and writes `~/.InterviewCheck/owner.license`.
  For another Mac, copy the identifier shown under Advanced on the sign in
  screen (or on the Account page) and pass it as `--device`.
- On the Mac, `OwnerLicenseGate` (file store, `OwnerLicenseVerifier` with
  CryptoKit, `IOKitDeviceIdentity`) resolves the file on every
  `AccessController.evaluate`. `AccessGatePolicy` treats a valid license as
  a floor: a live server grant is still reported when there is one, and in
  every other state (no account, checking, paywall, unreachable, invalid
  session) the owner's Mac is `allowed` as an admin. Signing out of the
  server does not lock the Mac; removing the license does.
- The Admin page still needs a server session, because accounts live on
  the server; the Account page offers the sign in form for that.
- Threat model: the file is public data, so leaking it gives nothing on
  another Mac (device binding) and nobody can forge one without the
  private key. The public key is part of the app's identity, not
  configuration.

## Checkout flow

1. Paywall calls `POST /v1/billing/checkout {plan}` and opens the returned
   Stripe URL in the browser.
2. Stripe returns to `/v1/billing/return`, which deep links to
   `InterviewCheck://billing/success` (registered in Info.plist) and tells the
   user to switch back.
3. The webhook syncs the subscription; the app polls `/v1/me` every few
   seconds for up to three minutes and unlocks as soon as it is active.

## Storage on the Mac

- Session token: Keychain, key `InterviewCheck.access.sessionToken`.
- Last snapshot: UserDefaults JSON with the fetch time, authenticated with
  an HMAC whose key lives in the Keychain, used only for the offline grace
  window the server granted. A clock set back before the fetch time does
  not extend grace.
- Server address: debug builds read `SettingsManager.accessServerBaseURL`
  (default `http://localhost:8787`) and show an editable field; release
  builds start on `AccessServerAddress.releaseOrigin`, which must be set to
  the deployed origin before shipping, and accept a stored override only
  when it targets loopback. To test a release build against a local server:
  `defaults write com.InterviewCheck.app InterviewCheck.accessServerBaseURL http://localhost:8787`.
  Plain `http` is accepted only for loopback.
- A bare 401 from a proxy or captive portal never signs the user out; only
  the server's own `session_invalid` or `unauthenticated` codes do.

## Where it shows up

- Overlay gate (`AccessGateView`, hosted by `MentorView`): sign in, create
  account, paywall, unreachable, with Quit in its header.
- Settings screen (gear icon in the overlay header, or Cmd+U), Account page:
  status, plan, manage billing, sign out, server.
- Settings screen, Admin page (admins only): stats, search, per user grants
  (30 days, 1 year, clear), promote or demote, disable or enable.

## Server

See `server/README.md` for setup, Stripe configuration, the API table, and
deployment (Dockerfile plus fly.toml). `npm test` runs 43 tests covering
entitlement rules, auth, webhooks with a fake Stripe gateway, and admin
guards such as never removing the last admin.

## Tests on the Mac side

`InterviewCheckTests/Access/` covers the gate policy, deep link parsing, server
address normalization, the API client against a stub transport, the
controller's sign in, revoke, offline, sign out, and checkout transitions,
and the owner license (a fixed vector signed by the Node tool, the file
store, the gate, and the controller floor semantics).
