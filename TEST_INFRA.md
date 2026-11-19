# InterviewCheck E2E Test Infrastructure (`TEST_INFRA.md`)

## 1. Purpose and Scope

This document defines the requirement driven, opaque-box Playwright and HTTP end-to-end test infrastructure for InterviewCheck under `portable/qa/e2e_suite/`. The suite verifies Features F3 through F13 and Requirements R1 through R3 against the running FastAPI (`portable/api/`) and Next.js (`portable/web/`) application without depending on internal implementation structure.

`TEST_READY.md` is withheld until Milestone M4, when M2 security hardening and M3 UI redesign are complete and Tiers 1 through 4 pass at 100%.

---

## 2. Feature Inventory (F3 to F13 / R1 to R3)

| Feature | Requirement | Milestone | Verification Scope |
|---|---|---|---|
| F3: Persistent Model Registry & Secret Encryption | R1 | M1 | SQLite schema `connected_models` and `model_audit`, Fernet/AES key encryption at rest, masked `key_hint` DTOs, exclusion of secrets from workspace backups. |
| F4: Model Admin API (CRUD, Toggle, Probe) | R1 | M1 | Live HTTP CRUD on `/api/admin/models`, enable/disable toggle, non-crashing provider probe status persistence (`connected` / `error` / `disabled`), atomic error responses. |
| F5: Dynamic Model Resolution & Provider Hooks | R1 | M1 | Dynamic resolution of enabled models in `authoring.py`, `audio.py`, `integrations.py`, `connection_catalog.py`, `/api/scoring/semantic`, and `/api/scoring/judge`. |
| F6: SSRF & Model Config Validation | R1, R3 | M1, M2 | Strict Pydantic validation (extra fields, bounds, provider capability matrix), HTTPS-only custom endpoints, blocking loopback, private, link-local, metadata IPs, and userinfo URLs with zero partial DB rows. |
| F7: Multi-Admin Auth & Fail-Closed Admin Protection | R3 | M2 | Fail-closed `401` (unauthenticated/forged cookie) and `403` (non-admin role) on all admin routes, multi-admin bootstrap/login without single-email lock, token rotation on privilege change. |
| F8: HTTP Security Headers, CSP & CSRF Hardening | R2, R3 | M2 | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Permissions-Policy`, `Content-Security-Policy` (no inline `onclick` in exports), HSTS over HTTPS, `X-InterviewCheck: 1` CSRF checks on `/api/*` and `/v1/*`, rate limiting, `server/` AdminRoutes UUID/limit validation. |
| F9: Prompt Injection, Secret Leakage & Status Minimization | R3 | M2 | Structured JSON framing in `integrations.py` and `scoring_hooks.py`, sanitized error messages without env vars or keys, gated/minimized `/api/integrations/status`, zero secrets in client bundles. |
| F10: Responsive Navigation & Shell Redesign | R2 | M3 | `WorkspaceShell` desktop sidebar and mobile drawer/header across `1440x900` and `390x844`, dark/light themes, keyboard skip link, zero clipped or overlapping controls. |
| F11: Model Administrative Panel UI | R1, R2 | M3 | `/admin/` UI workflows to list, register, configure, test connectivity (probe), toggle, disconnect models, inspect account admin/audit tabs, and view explicit error banners. |
| F12: Primary Workspace Routes Redesign | R2 | M3 | Functional and visual verification across `/`, `/interviews/`, `/interviews/new/`, `/interviews/review/`, `/interviews/brief/`, `/roles/`, `/connections/`, `/data/`, `/account/`, `/sample/`, `/trash/`. |
| F13: Visual Hierarchy & Screenshot Review Gate | R2 | M3 | Automated Playwright desktop (`1440x900`) and mobile (`390x844`) screenshot capture across all primary and admin routes for independent rubric evaluation. |

---

## 3. Test Architecture (`portable/qa/e2e_suite/`)

### 3.1 Opaque-Box Execution Boundary
- Tests communicate exclusively with the running application HTTP origin (`workspace_url` in `static`, `start`, or `dev` Next.js mode) through Playwright browser pages and `httpx.Client` sessions.
- No test imports or calls FastAPI database internals to perform CRUD assertions; state persistence is verified via API reads and full server restarts against the same temporary SQLite files.
- Developer workstation credentials and provider environment keys are scrubbed on every run (`INTERVIEWCHECK_*`, `ADMIN_*`, `STRIPE_*`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `AZURE_OPENAI_API_KEY`, `DEEPGRAM_API_KEY`).

### 3.2 Workspace and Server Harness (`harness.py`, `conftest.py`)
- **Isolated Workspace (`IsolatedWorkspace`)**: Allocates a unique `tmp_path` directory with `review.sqlite3`, `access.sqlite3`, and a test-only `INTERVIEWCHECK_MODEL_SECRET_KEY`. Supports `.start()`, `.stop()`, and `.restart()` on the same port and database files to verify persistence across restarts.
- **Frontend Modes**: Reuses the parent `--frontend` option (`static`, `dev`, `start`) and `launch_chromium` Chrome channel fallback from `portable/qa/conftest.py`.
- **Auth Helpers**:
  - `enable_embedded_auth(...)`: Configures `INTERVIEWCHECK_ACCESS_MODE=embedded` with multi-admin `ADMIN_EMAILS`, `ADMIN_BOOTSTRAP_SECRET`, and optional `INTERVIEWCHECK_SIGNUP_SECRET`.
  - `signup_account(...)` / `login_account(...)`: Registers or signs in admin and member accounts via `/api/integrations/access/signup` and `/api/integrations/access/login`, returning authenticated `httpx.Client` cookies or injecting session cookies into Playwright browser contexts.
- **Viewport Fixtures**:
  - `desktop_page`: Playwright browser context at `1440x900` with `reduced_motion="reduce"`.
  - `mobile_page`: Playwright browser context at `390x844` (`has_touch=True`, `is_mobile=True`) with `reduced_motion="reduce"`.
- **Telemetry Collectors**:
  - `ConsoleErrorCollector`: Attaches to `page.on("console")` (capturing `error` messages), `page.on("pageerror")` (uncaught exceptions), and `page.on("response")` (unexpected `5xx` responses unless suppressed for explicit negative probe tests).
  - `assert_no_horizontal_overflow(page)`: Verifies `document.documentElement.scrollWidth <= document.documentElement.clientWidth` at both `1440x900` and `390x844`.
  - `capture_screenshot(page, name, viewport_label)`: Captures full-page PNG artifacts into `INTERVIEWCHECK_E2E_SCREENSHOT_DIR` (or `tmp_path/screenshots`) for Tier 4 and M3 visual review.

### 3.3 macOS Playwright Audio Mocking Strategy
- Headless Chromium on macOS stalls on real `navigator.mediaDevices.getUserMedia({audio: true})` because CoreAudio has no virtual input device in CI/headless sessions, whereas `{video: true}` and Web Audio API `AudioContext` succeed cleanly.
- `install_audio_mock(page)` injects a `page.add_init_script(...)` shim that:
  1. Creates a synthetic `AudioContext` oscillator routed into `createMediaStreamDestination()` when `{audio: true}` is requested.
  2. Falls back to a synthetic canvas-backed video track when `{video: true}` is also requested in `getDisplayMedia`.
  3. Preserves real `MediaRecorder` encoding and WebSocket transport (`/api/integrations/live`) without hanging macOS headless Chromium.

---

## 4. Four-Tier Methodology and Pass Thresholds

| Tier | Scope | Required Pass Threshold | Gating |
|---|---|---|---|
| **Tier 1: Smoke and Contract Gate** | Primary routes render cleanly at `1440x900` and `390x844` with zero console errors, zero uncaught page exceptions, and zero horizontal overflow. Model Admin API CRUD, toggle, probe error handling, SSRF rejection, persistence across restart, and `401`/`403` auth/CSRF rejection via live HTTP. | **100% pass** (non-gated specs); M2/M3-gated specs marked `m2_gated` / `m3_gated` (`xfail` until M2/M3 complete). | Active at M1 (`b2e69e5`) |
| **Tier 2: Functional & Security Validation E2E** | Boundary and corner-case opaque-box validation across F3-F9 (`test_tier2_model_boundaries.py`, `test_tier2_security_boundaries.py`, `test_tier2_resolution_and_framing.py`, `test_tier2_exports_and_minimization.py`: 108 HTTP/API cases covering model schema/SSRF bounds, multi-admin auth/revocation, production mode, `/v1/*` CSRF, CSP/HSTS, rate limits, dynamic resolution, sanitization, and export escaping), plus M3 browser `/admin/` workflows once UI build completes. | **100% pass** (108/108 HTTP/API Tier 2 cases passing; UI `/admin/` workflows pending M3 completion) | Active at M2/M3 |
| **Tier 3: Cross-Viewport, State & Persistence Integrity** | Full layout parity at `1440x900` and `390x844` (no overlapping or clipped controls, readable contrast in dark and light themes), browser reload and server restart persistence, token rotation on role/password/disable changes, and backup export exclusion of encrypted keys. | **100% pass** | Active after M3 |
| **Tier 4: Real-World Application Scenarios** | End-to-end multi-step journeys combining auth, model fleet configuration, role authoring, live mocked audio interview capture, transcript import, evidence review, semantic/judge hooks, report/archive export, and admin audit inspection. | **100% pass** | Active at M4 Gate |

### 4.1 Tier 2 Boundary Suite Coverage (F3 to F9)
- `portable/qa/e2e_suite/test_tier2_model_boundaries.py`: F3 registry default atomicity, slug conflicts (`409`), filtering, secret-key mismatch probe resilience, F4 length/pattern/reserved-slug and numeric/strict-JSON bounds, `clearApiKey` vs key rotation, and F6 Azure allowlist and SSRF IPv4/IPv6/numeric/userinfo/port/DNS boundaries.
- `portable/qa/e2e_suite/test_tier2_security_boundaries.py`: F7 unauthenticated and non-admin rejections across `/api/admin*`, `/api/integrations/admin*`, `/v1/admin*`, session revocation on role/password/disable mutations, password min/max boundaries (9/10/200/201), last-admin `409` protection, `INTERVIEWCHECK_PRODUCTION=1` fail-closed startup and workspace gating, F8 `/v1/*` CSRF vs `/v1/billing/webhook`, security headers/HSTS, and `ADMIN_PROBE` (15) / `AI_REQUEST` (20) `429` rate limits with `Retry-After`.
- `portable/qa/e2e_suite/test_tier2_resolution_and_framing.py`: F5 dynamic authoring/scoring/audio resolution, `503` fail-closed checks, env-fallback suppression when DB models are disabled, and F9 input size/schema limits, error sanitization, and workspace backup credential exclusion.
- `portable/qa/e2e_suite/test_tier2_exports_and_minimization.py`: F8 HTML print XSS escaping, external `print.js` CSP, CSV formula neutralization, and F9 `/api/integrations/status` and `/api/integrations/catalog` auth-tier minimization.

---

## 5. Tier 4 Real-World Application Scenarios

1. **Scenario A: Multi-Admin Onboarding and Model Fleet Configuration**
   - Bootstrap two distinct administrators (`admin1`, `admin2`) under embedded mode while a third non-admin user (`member`) attempts and fails (`403`) to open `/admin/` or call `/api/admin/models`.
   - `admin1` registers OpenAI (`reference`), Anthropic (`judge`), and Deepgram (`transcription`) models via `/admin/`, rotates an API key without losing existing config, tests probe failure visibility on an invalid key, toggles a model off and on, and verifies `admin2` sees the exact persisted state and audit log entries after server restart.

2. **Scenario B: Consented Live Interview, Mocked Audio Capture, Review, and Export**
   - Authenticated operator creates a role with planned questions, opens `/interviews/new/`, records candidate consent, runs live microphone capture via `install_audio_mock(page)`, applies the transcript excerpt, adds reference material, runs evidence comparison, records disposition and interviewer note, and exports Markdown and archive CSV without inline script CSP violations.

3. **Scenario C: Security Boundary and Hostile Input Resilience**
   - Attempt unauthenticated access, cross-origin requests, missing `X-InterviewCheck: 1` headers on `/api/*` and `/v1/*`, SSRF endpoints (`http://127.0.0.1`, `https://169.254.169.254`, `https://localhost`, `https://user:pass@example.com`), malformed JSON (`NaN`, unknown fields), and prompt-injection payloads in interview answers. Verify explicit HTTP errors (`400`/`401`/`403`/`422`), zero secret leakage in responses or client bundles, and intact database state.

4. **Scenario D: Mobile Field Review, Backup Restore, and Visual Audit**
   - At `390x844` mobile viewport, navigate the redesigned shell drawer across `/`, `/interviews/`, `/roles/`, `/connections/`, `/data/`, `/account/`, and `/admin/`. Create a workspace backup on `/data/`, confirm encrypted model keys are excluded from the backup archive, restore into a clean session, and capture desktop and mobile screenshot artifacts across dark and light themes with zero clipping or overflow.
