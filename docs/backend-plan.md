# Connector backend: a plan for when InterviewCheck is sold to many companies

**Status:** proposal. Nothing here is built. It needs an owner decision on the
questions at the end before any work starts.

## Why a backend at all

Tonight's connectors run entirely on the Mac. Each company pastes its own keys,
and the keys stay in the interviewer's Keychain. That works for a pilot, but the
vendors expect two kinds of credentials to live on a server, not inside a desktop app:

1. **Partner OAuth secrets.** Greenhouse's partner sign-in, Lever's OAuth (Lever
   says production integrations must use it), and Workable's partner token all
   need a client secret that is registered once for InterviewCheck. That secret
   must not ship inside the app.
2. **Unified API workspace keys.** Merge, Kombo, Unified.to and Apideck each issue
   one secret key for InterviewCheck's account, plus a token or ID per customer.
   Whoever holds that key can read every customer's ATS data.

A Mac app can keep a company's own key safely. It cannot safely hold a key that
opens every company's data.

## What the server would do

Build on the existing access server (`server/`: Hono, SQLite, Stripe; deployed
with `fly.toml`). Add three things.

**1. Organizations.** Companies, their members and an admin role. This is the
"company seats" step already on the roadmap.
- `organizations(id, name, created_at)`
- `memberships(user_id, organization_id, role)`

**2. Connection broker.** The server holds the secrets and hands the app only
short-lived access tokens.
- `POST /connections/:system/start`: returns a URL to open in the browser, with
  the server as the OAuth client. Examples are a Merge Link token or Magic Link,
  a Kombo Connect link, or a Greenhouse/Lever partner authorize URL.
- `GET /connections/:system/callback`: the vendor redirects here. The server
  stores the per-organization token encrypted at rest.
- `POST /connections/:system/token`: the app asks for a short-lived access token.
  - For direct partner OAuth (Greenhouse, Lever, Workable), the server refreshes
    the token and returns it, single-flight per organization.
  - For unified APIs, it returns a proxied, scoped call path (below).
- `DELETE /connections/:system`: an organization admin disconnects.

**3. Unified-API proxy.** The workspace key never leaves the server.
- `GET /proxy/:system/*` forwards only the read endpoints the app uses (jobs,
  candidates, interviews, attachments).
- `POST /proxy/:system/notes` forwards the one write, Send Summary.
- Every call is checked against the caller's organization and logged in the
  existing audit log.

**On the Mac**, each connector keeps its current code. Only the credential source
changes: a new `BrokeredCredentials` gets tokens from the server instead of the
Keychain. Self-serve, paste-your-own-key setups keep working for companies that
prefer them.

## Security notes

- Encrypt stored vendor tokens with a server-held key (for example libsodium
  secretbox with a key from Fly secrets). Rotate it with a key id per row.
- Proxy only allowlisted paths and methods. Never forward arbitrary URLs.
- Rate-limit per organization. Kombo shares 300 requests per minute across all
  customers.
- No interview content passes through the server except the Send Summary note.
  Transcripts, scores and audio stay on the Mac, as today.

## Order of work (rough)

1. Organizations and memberships, and seat billing in Stripe (about 2-3 days).
2. Merge or Kombo broker plus proxy. One unified API covers Workday, iCIMS and
   SuccessFactors at once (about 3 days).
3. Greenhouse partner OAuth. Apply to the partner program first (2 days of code;
   the agreement takes weeks).
4. Lever and Workable partner flows.

## Questions for the owner

- Which unified API? **Kombo** has the best interview data in one call and data
  refreshed about every 3 hours. **Merge** has the best enterprise coverage but
  syncs once a day on its entry plan. **Unified.to** is live and reaches iCIMS
  and Jobvite. Pricing differs: Merge starts at $650 a month; Kombo and Unified.to
  are custom or usage-based.
- Apply to the Greenhouse, Lever and Workable partner programs now? They take time.
- Is self-serve (paste your own keys) a selling point to keep, for security-minded
  buyers?
