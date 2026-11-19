# InterviewCheck Release Audit (`RELEASE_AUDIT.md`)

**Branch**: `feat/interviewcheck-production` (based on M9 commit `0246ed6adbce468822791271d683f9bb1c7949b2` plus M10 working tree fixes)  
**Audit Date (UTC)**: `2026-11-19`  
**Release Status**: `PASS` across static, Next.js production server (`start`), and Next.js development (`dev`) modes

## 1. Milestone Summary (M0 through M10)

| Milestone | Scope | Key Deliverables | Status |
|---|---|---|---|
| M0 | Git and test harness readiness | Branch `feat/interviewcheck-production`, isolated Next distDir, startup retry, Chrome fallback | DONE |
| M1 | Model registry and Admin API | Encrypted `connected_models` table, CRUD/toggle/probe endpoints, SSRF guard, dynamic provider hooks | DONE |
| M2 | Website and admin security hardening | Multi-admin fail-closed gates, CSP/HSTS/CSRF/rate limits, prompt framing, secret hygiene | DONE |
| M3 | Responsive UI and Model Admin Panel | Redesigned shell, primary workspace routes, `/admin/` model/account/audit console, visual rubric | DONE |
| M4 | Opaque-box E2E suite | 4-tier Playwright suite (`portable/qa/e2e_suite/`) and `TEST_READY.md` | DONE |
| M5 | Tier 5 adversarial hardening | TOCTOU/CSP/focus-trap fixes, Node hardening, adversarial API and UI coverage | DONE |
| M6 | Model telemetry and fallback routing | Health check history, latency tracking, fallback chains, RPM/retry quotas | DONE |
| M7 | Review workbench and accessibility | Embeddings/AI judge hooks, WCAG AA keyboard/ARIA fixes, mobile review polish | DONE |
| M8 | Security fuzzing and audit suite | Audit cursor pagination, CSV/JSON export with formula neutralization, SHA-256 backup validation | DONE |
| M9 | Performance and scale optimization | Bundle splitting, SQLite catalog indexes, FTS5 search, Node/Python v6 schema parity | DONE |
| M10 | Pre-release fixes and final audit | `WorkspaceSearch.tsx` focus restore, `next start` CSP/security headers, unified `qa_browser` fixture | DONE |

## 2. M10 Pre-Release Fixes Applied

1. **Search dialog focus restoration (`portable/web/components/WorkspaceSearch.tsx`)**: Captured `document.activeElement` in `previousFocusRef` only when it is an `HTMLElement` other than `document.body` and `document.documentElement`, and tracked the active modal session with `openCycleRef`. Guarded `onClose` with `if (dialog.current?.open || !openCycleRef.current) return` before clearing `openCycleRef.current = false` so stale queued `<dialog>` `close` events from a rapid close-reopen-close sequence cannot run focus restoration twice and steal focus to `trigger.current`. When closing without navigation, restored focus to `previousFocusRef.current` if connected and verified `document.activeElement === restoreTarget`, falling back to `trigger.current` when focus cannot land (such as `document.body`, detached, or disabled targets). Verified by `qa/test_search_trash.py::test_keyboard_search_and_version_bound_trash`, `test_search_dialog_focus_fallback_on_body_and_disabled_target`, and `test_search_dialog_rapid_close_reopen_keeps_focus`.
2. **Next.js `start` security headers and per-route CSP hashes (`portable/web/next.config.ts`, `portable/web/inject-csp.mjs`, `portable/web/package.json`, `portable/web-runtime.mjs`, `portable/qa/next_frontend.py`)**: Configured baseline security headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Permissions-Policy`) on non-API routes in server mode while keeping `output: "export"` warning-free and error-free. Added post-build `inject-csp.mjs` to compute SHA-256 hashes of prerendered inline `<script>` elements into `routes-manifest.json` matching `portable/api/security_headers.py` HTML CSP without `'unsafe-inline'` in `script-src`. Fixes `test_baseline_security_headers_on_api_and_html` and `test_m8_browser_xss_escaping_csp_and_responsive_viewports` under `--frontend=start`.
3. **Playwright session fixture unification (`portable/qa/conftest.py`, `portable/qa/e2e_suite/conftest.py`, `portable/qa/test_m3_admin_ui.py`)**: Added session-scoped `qa_browser` in `portable/qa/conftest.py` and reused it in `browser_page`, `e2e_browser`, and `m3_browser` with per-test isolated `BrowserContext` teardown, eliminating the nested `sync_playwright()` asyncio loop failure when running `qa/` and `qa/e2e_suite/` together.

## 3. Verified Suite Results (Post-Fix)

Run from `/Users/abekhadra/Desktop/STARKTECH/InterviewCheck` with `PATH="/opt/homebrew/bin:$PATH"`:

| Check | Command | Result |
|---|---|---|
| Source size gate | `python3 scripts/check-source-size.py` | `627` first-party files, all `<= 400` lines (`PASS`) |
| Web source line cap | `find portable/web/app portable/web/components portable/web/lib -type f \| xargs wc -l` | Max `380` lines (`workbench.css`) (`PASS`) |
| Web typecheck, build, export | `cd portable/web && npm run typecheck && npm run build && npm run export` | Exit `0`, `0` warnings, `portable/web/out/` (`2.4M`) updated |
| Node account service | `cd server && npm run typecheck && npm test` | `12` test files, `109 passed` (`415ms`) |
| Python backend suite | `cd portable && INTERVIEWCHECK_REQUIRE_WEB_OUT=1 PYTHONPATH=. .venv/bin/pytest tests -q` | `434 passed` (`18.09s`) |
| Search and trash E2E (`start`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_search_trash.py -v --frontend=start` | `4 passed` (`14.83s`) |
| Search and trash E2E (`static`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_search_trash.py -v --frontend=static` | `4 passed` (`3.92s`) |
| Admin UI E2E (`start`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_m3_admin_ui.py -v --frontend=start` | `3 passed` (`19.32s`) |
| Access service E2E (`start`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_access_service.py -v --frontend=start` | `2 passed` (`11.61s`) |
| Legacy QA suite (`start`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa --ignore=qa/e2e_suite --ignore=qa/test_m3_admin_ui.py --ignore=qa/test_access_service.py -q --frontend=start` | `59 passed` (`68.29s`) |
| Unified QA and E2E (`start`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa --ignore=qa/test_m3_admin_ui.py --ignore=qa/test_access_service.py -q --frontend=start` | `257 passed` (`220.99s`) |
| Opaque-box E2E (`static`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ -q --frontend=static` | `198 passed` (`153.85s`) |
| Browser smoke (`static`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_browser.py -q --frontend=static` | `3 passed` (`5.13s`) |
| Dev mode smoke (`dev`) | `cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_session_lifecycle.py qa/test_capture.py qa/test_webhook_transport.py qa/test_connected_ui.py::test_admin_grants_access_through_account_page -q --frontend=dev` | `5 passed` (`15.10s`) |

## 4. Security, Bundle, and Accessibility Status

1. **Security**: Fail-closed `401`/`403` admin gates, `X-InterviewCheck: 1` CSRF enforcement on `/api/*` and `/v1/*`, SSRF URL and IP validation for model endpoints, encrypted model API keys excluded from workspace backups, CSV formula neutralization, strict SHA-256 CSP without `'unsafe-inline'` in `script-src`, and `LocalBoundary` host/origin guards are verified across both `static` and `start` modes.
2. **Bundle**: `portable/web/out/` totals `2.4M` (`_next/static/chunks/` largest shared chunk `236K`) and embeds zero server secrets.
3. **Accessibility and Visual Rubric**: Evaluated in M10 (`qa/m3_screenshot_pack.py`) across `56` screenshots (`14` routes and auth states, `dark` and `light` themes, `1440x900` desktop and `390x844` mobile) with `0` horizontal overflow failures, `0` clipping failures, `0` overlap failures, `0` console or CSP errors, `0` contrast failures, and minimum control border contrast `3.07`.

## 5. Open Pull Requests on `bogdang40/InterviewCheck`

| PR | Branch | Base | Title |
|---|---|---|---|
| `#16` | `feat/m9-performance-scale` | `main` | `feat(m9): bundle budget, SQLite catalog indexes, FTS5 search, and v6 schema parity` |
| `#15` | `feat/m8-security-audit` | `main` | `feat(m8): security fuzzing, admin audit log, and backup integrity` |
| `#14` | `feat/m7-workbench-accessibility` | `main` | `feat(m7): review workbench AI hooks, WCAG AA accessibility, and mobile polish` |
| `#13` | `feat/m6-telemetry-routing` | `main` | `feat(m6): model telemetry, fallback chain routing, RPM/retry quotas, and admin health drawer` |
| `#12` | `feat/m5-tier5-hardening` | `main` | `feat(m5): Tier 5 adversarial hardening, TOCTOU/CSP/focus-trap fixes, and Node hardening (F15)` |
| `#11` | `feat/m4-e2e-suite` | `main` | `feat(m4): 4-tier Playwright E2E suite and TEST_READY gate (F14)` |
| `#10` | `feat/m3-ui-model-admin` | `main` | `feat(m3): responsive UI redesign and model admin panel (F10-F13)` |
| `#9` | `feat/m2-security-hardening` | `main` | `feat(security): harden website and admin auth, CSP, CSRF, and secret hygiene (M2)` |
| `#8` | `feat/m1-model-admin-api` | `main` | `Add encrypted model registry, admin CRUD/probe API, SSRF guard, and dynamic model wiring (M0-M1)` |
| `#7` | `feature/interview-delivery-round` | `main` | `Add private revision history and portable role kits` |
