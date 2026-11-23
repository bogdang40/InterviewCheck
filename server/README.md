# InterviewCheck access server

Accounts, Stripe subscriptions, entitlements, and the admin API that the
InterviewCheck macOS app talks to. The desktop app cannot hold a Stripe secret
or decide its own entitlement, so this small service is the source of truth.

Stack: Node 22, Hono, `node:sqlite` (no native modules), Stripe SDK, zod,
vitest. Single process, single SQLite file, deployable anywhere a Node
process and a persistent disk exist.

## Run locally

```bash
cd server
npm install
cp .env.example .env      # edit ADMIN_EMAILS at minimum
set -a; source .env; set +a
npm run dev
```

`GET http://localhost:8787/health` should answer `{"ok":true,...}`.
Set `HOST=127.0.0.1` to bind the service to local traffic during development.

Without Stripe keys the server still runs: signup, login, admin, and
complimentary grants all work, and checkout answers `503 billing_not_configured`.
That is enough to develop the app and to hand out access manually.

## Stripe setup (once)

1. In the Stripe dashboard create one product ("InterviewCheck") with two
   recurring prices, monthly and annual. Copy both price ids into
   `STRIPE_PRICE_MONTHLY` and `STRIPE_PRICE_ANNUAL`.
2. Copy the secret key into `STRIPE_SECRET_KEY`.
3. Enable the Customer Portal (Settings, Billing, Customer portal).
4. Webhook. For local development:

   ```bash
   stripe listen --forward-to localhost:8787/v1/billing/webhook
   ```

   Copy the printed signing secret into `STRIPE_WEBHOOK_SECRET`. In
   production add an endpoint for `https://<host>/v1/billing/webhook` with
   these events: `checkout.session.completed`, `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`,
   `customer.subscription.paused`, `customer.subscription.resumed`.

## Owner license (use the app without this server)

The owner's own Mac should not depend on this server being up. Generate a
key pair once, embed the public key in the app, and issue a device bound
license file:

```bash
npm run owner-license -- keygen
# paste the printed public key into
# InterviewCheck/Access/Services/OwnerLicensePublicKey.swift, then rebuild
npm run owner-license -- issue --email you@example.com --device auto
```

`issue` writes `~/.InterviewCheck/owner.license`; the app reads it on every
access check. `--device auto` reads this Mac's IOPlatformUUID; for another
Mac pass the identifier the app shows under Advanced on the sign in screen.
`npm run owner-license -- verify --public-key <base64> --device auto`
checks a file the way the app will. The private key
(`~/.InterviewCheck/owner-signing.key`) never goes into the repository.

## Admin privileges

The role is a column on the `users` table. A signup starts as `admin` only
when both hold: the email is in `ADMIN_EMAILS` (comma separated allow list)
and the request carries `adminSecret` equal to `ADMIN_BOOTSTRAP_SECRET`. The
macOS sign in form exposes that field under Advanced when creating an
account. Signup has no email verification, so the allow list alone is not
trusted; without the secret anyone could claim an admin address first.

Once your account exists you can clear or rotate the secret, provided
`TOTP_ENCRYPTION_KEY` is set (see below). Without that key, two factor seeds
are encrypted with a key derived from `ADMIN_BOOTSTRAP_SECRET` (or, when it is
empty, `STRIPE_SECRET_KEY`, then `STRIPE_WEBHOOK_SECRET`, then a key file next
to the database), and changing any of those makes existing seeds unreadable.
Any admin can promote or demote anyone through the API or the in app Admin tab. To promote an
existing account without the secret:

```bash
sqlite3 data/access.sqlite "UPDATE users SET role = 'admin' WHERE email = 'you@example.com';"
```

Admins always have access, regardless of subscription state.

## Two factor seed encryption

TOTP seeds are stored with AES-256-GCM. Set `TOTP_ENCRYPTION_KEY` to 32 random
bytes in base64 (`openssl rand -base64 32`) and keep it with your other
secrets. `TOTP_ENCRYPTION_KEY_ID` (default `k1`) names it inside each stored
value, so keys can rotate:

1. Generate a new key. Set it as `TOTP_ENCRYPTION_KEY` with a new
   `TOTP_ENCRYPTION_KEY_ID`, and move the old one into
   `TOTP_ENCRYPTION_RETIRED_KEYS` as `oldkid:oldbase64` (comma separated).
2. Restart. Startup re-encrypts every seed it can open under the new key, and
   each successful verification does the same.
3. Once the startup log no longer reports re-encrypted seeds, remove the
   retired key.

Upgrading a deployment that predates the key: set `TOTP_ENCRYPTION_KEY` and
restart while `ADMIN_BOOTSTRAP_SECRET` (and the Stripe keys) are unchanged.
Startup moves the old seeds onto the new key; only after that is it safe to
clear or rotate the bootstrap secret. Without the key the server keeps the old
behaviour and logs a warning at startup.

A seed that cannot be decrypted never causes a 500: the server logs a
sanitized error, still accepts the user's backup codes, and otherwise answers
`401 invalid_totp_code`. An admin can clear a user's two factor setup with
`POST /v1/admin/users/:id/reset-totp`, which also signs that user out
everywhere and is recorded in the audit log.

## Behind a proxy

Set `TRUST_PROXY=true` only when a trusted reverse proxy (Fly, nginx) sits
in front of the server, and set `TRUSTED_PROXY_HEADER` to the one header that
proxy writes:

* `fly-client-ip` (default): Fly sets it and replaces any copy the client sent.
* `x-forwarded-for`: for nginx and similar proxies that append the client
  address; only the last hop is used.

The rate limiters then key on that header alone. Any other forwarded header
is ignored, because the client controls it (behind nginx a client could send
a fresh `Fly-Client-IP` on every request). With `TRUST_PROXY` off, forwarded
headers are ignored entirely. Chains of several proxies that each append to
`X-Forwarded-For` are not supported; terminate at one proxy.

Each limiter tracks at most 5000 distinct addresses. When all of them are
live, new addresses share one overflow bucket with the same limit, so a flood
of fresh addresses makes new clients wait (429) rather than resetting anyone's
count.

## Entitlement rules

Resolved by `src/domain/Entitlement.ts`, in this order:

1. Disabled account: no access.
2. Admin role: access, never expires.
3. Live Stripe subscription: `active` or `trialing` until the period end,
   or `past_due` for `PAST_DUE_GRACE_DAYS` after the row entered that state
   (Stripe advances the period before retrying the card, so the period end
   is not a usable anchor).
4. Complimentary grant from an admin (`complimentaryUntil`): access until then.
5. Trial (`TRIAL_DAYS` at signup, default 0): access until it ends.
6. Otherwise: no access, the app shows the paywall.

Every response carries `graceUntil`, the moment until which the desktop app
may keep working on its cached snapshot if the network is unavailable.

## API

All JSON, all under `/v1`. Authenticated routes take `Authorization: Bearer <token>`.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| POST | `/auth/signup` | none | `{email, password, deviceName?, adminSecret?}` returns `{token, user, entitlement, subscription}` |
| POST | `/auth/login` | none | same body and response as signup |
| POST | `/auth/logout` | user | revokes the token |
| GET | `/me` | user | current `{user, entitlement, subscription, serverTime}` |
| GET | `/billing/plans` | none | `{configured, plans}` |
| POST | `/billing/checkout` | user | `{plan}` returns `{url}` to open in the browser |
| POST | `/billing/portal` | user | returns `{url}` for the Stripe Customer Portal |
| POST | `/billing/webhook` | Stripe signature | applies subscription changes idempotently |
| GET | `/billing/return` | none | browser landing page that deep links to `InterviewCheck://billing/<status>` |
| GET | `/admin/stats` | admin | counts |
| GET | `/admin/users?q=&limit=&cursor=` | admin | paginated users with entitlement |
| GET | `/admin/users/:id` | admin | one user |
| PATCH | `/admin/users/:id` | admin | `{role?, disabled?, complimentaryUntil?}` |
| POST | `/admin/users/:id/reset-totp` | admin | removes the user's two factor setup and revokes their sessions |
| GET | `/admin/audit?limit=` | admin | recent audit entries |

Errors are `{"error": {"code", "message"}}` with a meaningful status.
Credential endpoints are rate limited to 10 attempts per minute per address,
sign in additionally to 10 failed attempts (password or second factor) per
email per 15 minutes from any address, which also answers `429 rate_limited`
for emails that have no account,
request bodies are capped at 256 KB, and webhook deliveries are applied
from Stripe's current subscription state so out of order events cannot
revive a cancelled plan.

## Tests

```bash
npm test
```

The suite drives the real HTTP app against an in-memory database with a
fake Stripe gateway, so webhook and entitlement behaviour is covered end to
end without network access.

## Deploy

`Dockerfile` and `fly.toml` are included. Any host that runs a Node 22
container with a persistent volume for `DATABASE_PATH` works. Set
`PUBLIC_BASE_URL` to the public origin so Stripe return pages resolve.

Run one account service writer per database. Before upgrading an existing paid
service, pause checkout and take a consistent SQLite backup. Let existing
Checkout Sessions expire or close them in Stripe. Compare active subscriptions
and customer IDs in Stripe with the account database, including any customers
created by concurrent checkouts on older versions. Keep the original backup and
the Stripe events received after it for rollback and replay. Reopen checkout
after signed webhook delivery, renewal, cancellation, and account restore pass
on the deployment. The [backend review](../docs/backend-production-review.md)
records remaining release checks.
