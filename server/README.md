# memanager access server

Accounts, Stripe subscriptions, entitlements, and the admin API that the
memanager macOS app talks to. The desktop app cannot hold a Stripe secret
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

Without Stripe keys the server still runs: signup, login, admin, and
complimentary grants all work, and checkout answers `503 billing_not_configured`.
That is enough to develop the app and to hand out access manually.

## Stripe setup (once)

1. In the Stripe dashboard create one product ("memanager") with two
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
# memanager/Access/Services/OwnerLicensePublicKey.swift, then rebuild
npm run owner-license -- issue --email you@example.com --device auto
```

`issue` writes `~/.memanager/owner.license`; the app reads it on every
access check. `--device auto` reads this Mac's IOPlatformUUID; for another
Mac pass the identifier the app shows under Advanced on the sign in screen.
`npm run owner-license -- verify --public-key <base64> --device auto`
checks a file the way the app will. The private key
(`~/.memanager/owner-signing.key`) never goes into the repository.

## Admin privileges

The role is a column on the `users` table. A signup starts as `admin` only
when both hold: the email is in `ADMIN_EMAILS` (comma separated allow list)
and the request carries `adminSecret` equal to `ADMIN_BOOTSTRAP_SECRET`. The
macOS sign in form exposes that field under Advanced when creating an
account. Signup has no email verification, so the allow list alone is not
trusted; without the secret anyone could claim an admin address first.

Once your account exists you can clear the secret. Any admin can promote or
demote anyone through the API or the in app Admin tab. To promote an
existing account without the secret:

```bash
sqlite3 data/access.sqlite "UPDATE users SET role = 'admin' WHERE email = 'you@example.com';"
```

Admins always have access, regardless of subscription state.

## Behind a proxy

Set `TRUST_PROXY=true` only when a trusted reverse proxy (Fly, nginx) sits
in front of the server. The credential rate limiter then keys on the proxy
supplied client address (`fly-client-ip`, else the last `x-forwarded-for`
hop). With it off, forwarded headers are ignored entirely.

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
| GET | `/billing/return` | none | browser landing page that deep links to `memanager://billing/<status>` |
| GET | `/admin/stats` | admin | counts |
| GET | `/admin/users?q=&limit=&cursor=` | admin | paginated users with entitlement |
| GET | `/admin/users/:id` | admin | one user |
| PATCH | `/admin/users/:id` | admin | `{role?, disabled?, complimentaryUntil?}` |
| GET | `/admin/audit?limit=` | admin | recent audit entries |

Errors are `{"error": {"code", "message"}}` with a meaningful status.
Credential endpoints are rate limited to 10 attempts per minute per address,
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
