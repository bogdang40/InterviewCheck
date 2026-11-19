# InterviewCheck E2E Test Readiness (`TEST_READY.md`)

**Gate Verdict**: `READY` (Milestone M4 E2E Gate Passed)  
**Verified Timestamp (UTC)**: `2026-11-19T07:06:33Z`  
**E2E Suite Result (`--frontend static`)**: `168 passed` (`0 failed, 0 xfailed, 0 xpassed, 0 skipped`)  
**Stale Marker Scan (`grep -rn "xfail\|m2_gated\|m3_gated" portable/qa/e2e_suite/`)**: `0 matches`

---

## 1. Verified Suite Counts

| Suite / Check | Scope | Command Result | Status |
|---|---|---|---|
| `portable/qa/e2e_suite/` (Full M4 Gate, `--frontend static`) | Tiers 1 to 4 (`14` test modules) | `168 passed` in `85.50s` (`0 failed, 0 xfailed, 0 xpassed, 0 skipped`) | PASS |
| Tier 1: Smoke and Contract Gate (`-m tier1`) | Route rendering (`1440x900` and `390x844`), audio mock, headers/CSP, Model Admin API CRUD/SSRF/CSRF | `40/40 passed` (`14` API + `26` route/smoke) | PASS |
| Tier 2: Functional and Security Validation (`-m tier2`) | Model schema/SSRF boundaries, multi-admin auth/revocation, production mode, rate limits, dynamic resolution, prompt framing, export escaping | `108/108 passed` (`95` model + `6` security + `5` resolution/framing + `2` exports/minimization) | PASS |
| Tier 3: Cross-Viewport, State and Persistence (`-m tier3`) | `/admin/` UI workflows, reload/restart persistence, backup secret exclusion, dark/light themes, desktop/mobile layout parity | `14/14 passed` (`5` admin UI + `4` persistence/restart + `5` viewport/themes) | PASS |
| Tier 4: Real-World Application Scenarios (`-m tier4`) | Scenarios A through F (multi-admin fleet, live mocked audio interview, hostile input resilience, mobile backup/restore, transcript lineage, catalog setup) | `6/6 passed` (`2` admin/security + `2` interview lifecycle + `2` mobile/catalog) | PASS |
| Restart Stress Check (`test_tier3_persistence_restart.py`, 5 consecutive runs, `--frontend static`) | Same-port `IsolatedWorkspace.restart()` + page quiescence and unmount | `5/5` runs passed (`4 passed` per run, ~`8.0s` each) | PASS |
| Restart Next.js Proxy Check (`test_tier3_persistence_restart.py`, `--frontend start`) | `IsolatedWorkspace._wait_ready()` against FastAPI and Next.js proxy `/api/health` | `4 passed` in `20.58s` | PASS |
| `portable/qa/test_*.py` (`--frontend static`, `PATH="/opt/homebrew/bin:$PATH"`) | Legacy + M3 Playwright QA suite (including `qa/test_local_audio_check.py`: `2 passed`) | `62 passed` in `91.93s` | PASS |
| `portable/tests/` (Unit and Integration) | Backend model registry, encryption, SSRF, auth, CSP/HSTS, bundle secrets | `321 passed, 4 xfailed` in `6.77s` (4 `xfail`s are M5 T5-02/T5-05/T5-06 specs in `tests/test_tier5_backend_gaps.py`) | PASS |
| `server/test/` (Node 22 / Hono Access and Billing) | Vitest (`11` test files) | `105 passed` in `386ms` | PASS |
| Source Size Gate (`scripts/check-source-size.py`) | First-party source and test line limits (`<= 400` lines) | `610` first-party files, all `<= 400` lines | PASS |
| Web TypeScript Check (`npm --prefix portable/web run typecheck`) | `tsc --noEmit` on `portable/web/` (`out/index.html` and `.next-server/BUILD_ID` present) | Exit `0` | PASS |

---

## 2. Feature Coverage Matrix (F3 to F13)

| Feature | Requirement | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|---|
| **F3**: Persistent Model Registry and Secret Encryption | R1 | `test_tier1_model_admin_api.py` (`14` total API tests) | `test_tier2_model_boundaries.py`, `test_tier2_resolution_and_framing.py` | `test_tier3_persistence_restart.py` (`test_connected_models_persist_across_browser_reload_and_server_restart`, `test_workspace_backup_download_excludes_model_secrets_and_restores_into_fresh_workspace`) | `test_tier4_admin_fleet_scenarios.py` (Scenario A), `test_tier4_mobile_and_catalog_scenarios.py` (Scenario D) |
| **F4**: Model Admin API (CRUD, Toggle, Probe) | R1 | `test_tier1_model_admin_api.py` (`test_admin_routes_fail_closed_and_require_csrf`, `test_multi_admin_model_crud_toggle_probe_and_restart_persistence`) | `test_tier2_model_boundaries.py` (`95` cases) | `test_tier3_admin_ui_workflows.py` (`test_admin_model_register_configure_rotate_probe_error_toggle_filter_and_disconnect`) | `test_tier4_admin_fleet_scenarios.py` (Scenario A) |
| **F5**: Dynamic Model Resolution and Provider Hooks | R1 | Covered via F3/F4 API gate | `test_tier2_resolution_and_framing.py` (`3` dynamic resolution and fail-closed `503` cases) | Verified via admin model toggles + review workflows | `test_tier4_interview_lifecycle_scenarios.py` (Scenario B), `test_tier4_mobile_and_catalog_scenarios.py` (Scenario F) |
| **F6**: SSRF and Model Config Validation | R1, R3 | `test_tier1_model_admin_api.py` (`10` parametrized SSRF/config cases) | `test_tier2_model_boundaries.py` (`14` Azure/capability + `26` SSRF boundary cases) | `test_tier3_admin_ui_workflows.py` | `test_tier4_admin_fleet_scenarios.py` (Scenario C) |
| **F7**: Multi-Admin Auth and Fail-Closed Protection | R3 | `test_tier1_model_admin_api.py` (`test_admin_routes_fail_closed_and_require_csrf`, `test_admin_login_after_logout_preserves_model_access`) | `test_tier2_security_boundaries.py` (`4` auth/revocation/production-mode cases) | `test_tier3_admin_ui_workflows.py` (`test_admin_gate_fails_closed_for_local_unauth_and_non_admin_browser_sessions`, `test_admin_accounts_role_promotion_disable_and_cross_context_token_revocation`, `test_account_password_rotation_revokes_other_browser_context_session`) | `test_tier4_admin_fleet_scenarios.py` (Scenarios A, C) |
| **F8**: HTTP Security Headers, CSP and CSRF Hardening | R2, R3 | `test_tier1_model_admin_api.py` (`test_m2_v1_mutations_require_csrf_header`), `test_tier1_smoke_routes.py` (`test_baseline_security_headers_on_api_and_html`, `test_m2_security_headers_csp_and_permissions_policy`) | `test_tier2_security_boundaries.py` (`/v1/*` CSRF, HSTS, rate limits), `test_tier2_exports_and_minimization.py` (XSS, `print.js` CSP, CSV formula neutralization) | Verified on every browser test via `ConsoleErrorCollector` | `test_tier4_interview_lifecycle_scenarios.py` (Scenario B), `test_tier4_admin_fleet_scenarios.py` (Scenario C) |
| **F9**: Prompt Injection, Secret Leakage and Status Minimization | R3 | Masked `key_hint` and secret exclusion checks in `test_tier1_model_admin_api.py` | `test_tier2_resolution_and_framing.py` (input framing, error sanitization, backup hygiene), `test_tier2_exports_and_minimization.py` (`test_status_and_catalog_minimization_across_auth_tiers`) | Secret absence verified in DOM and backup archives in `test_tier3_persistence_restart.py` and `test_tier3_admin_ui_workflows.py` | `test_tier4_admin_fleet_scenarios.py` (Scenario C), `test_tier4_mobile_and_catalog_scenarios.py` (Scenario F) |
| **F10**: Responsive Navigation and Shell Redesign | R2 | `test_tier1_smoke_routes.py` (`11` desktop + `11` mobile primary routes + `/admin/` desktop and mobile parity) | N/A (UI) | `test_tier3_viewport_themes.py` (`5` theme persistence, contrast, overflow, and mobile drawer/skip-link tests) | `test_tier4_mobile_and_catalog_scenarios.py` (Scenario D) |
| **F11**: Model Administrative Panel UI | R1, R2 | `test_tier1_smoke_routes.py` (`test_m3_admin_route_renders_without_errors` on `1440x900` and `390x844`) | N/A (UI) | `test_tier3_admin_ui_workflows.py` (`5` tests), `test_tier3_persistence_restart.py` (`test_connected_models_persist_across_browser_reload_and_server_restart`) | `test_tier4_admin_fleet_scenarios.py` (Scenarios A, C), `test_tier4_mobile_and_catalog_scenarios.py` (Scenario D) |
| **F12**: Primary Workspace Routes Redesign | R2 | `test_tier1_smoke_routes.py` (`22` parametrized primary route checks across `1440x900` and `390x844`) | N/A (UI) | `test_tier3_persistence_restart.py`, `test_tier3_viewport_themes.py` | `test_tier4_interview_lifecycle_scenarios.py` (Scenarios B, E), `test_tier4_mobile_and_catalog_scenarios.py` (Scenarios D, F) |
| **F13**: Visual Hierarchy and Screenshot Review Gate | R2 | Full-page screenshots captured on all `11` primary routes + `/admin/` at `1440x900` and `390x844` via `capture_screenshot` | N/A (UI) | Dark and light theme + desktop and mobile layout parity verified in `test_tier3_viewport_themes.py` | Multi-route screenshot artifacts captured in Scenario D (`test_tier4_mobile_and_catalog_scenarios.py`) |

---

## 3. Reproducible Commands

Run all commands from `/Users/abekhadra/Desktop/STARKTECH/InterviewCheck` with Node 22 on `PATH`:

```bash
export PATH="/opt/homebrew/bin:$PATH"

# 1. Full M4 E2E suite (static mode: 168 passed)
cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ --frontend static -v

# 2. Per-tier execution
cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ -m tier1 --frontend static -q
cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ -m tier2 --frontend static -q
cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ -m tier3 --frontend static -q
cd portable && PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ -m tier4 --frontend static -q

# 3. Screenshot artifact export directory (optional)
cd portable && INTERVIEWCHECK_E2E_SCREENSHOT_DIR=/tmp/ic-e2e-screenshots PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/ --frontend static -q

# 4. Restart stress check (5 consecutive runs)
cd portable && for i in 1 2 3 4 5; do PYTHONPATH=. .venv/bin/pytest qa/e2e_suite/test_tier3_persistence_restart.py --frontend static -q || exit 1; done

# 5. Companion suites and hygiene checks
cd portable && PYTHONPATH=. .venv/bin/pytest qa/test_*.py --frontend static -q
cd portable && PYTHONPATH=. .venv/bin/pytest tests/ -q
cd server && npm test
python3 scripts/check-source-size.py
npm --prefix portable/web run typecheck
```

---

## 4. Known Boundaries and Assumptions

1. **Audio mocking on macOS headless Chromium**: `install_audio_mock(page)` (`portable/qa/e2e_suite/harness.py`) injects a synthetic `AudioContext` oscillator and canvas video track for `getUserMedia` and `getDisplayMedia` because macOS headless Chromium has no CoreAudio input device. In `portable/qa/test_local_audio_check.py`, the `getDisplayMedia` test shim pairs real `getUserMedia({audio: true})` with a `<canvas>.captureStream(10)` video track so `Permissions-Policy: camera=()` is respected without `camera` violations.
2. **Offline synthetic provider probe tests**: Model Admin probe tests use synthetic non-secret API keys (for example `sk-e2e-...`) to verify explicit HTTP `400`/`502`/`504` error handling and `status="error"` persistence without calling external paid provider APIs with real credentials. Workstation provider keys are scrubbed on every run (`SCRUBBED_ENV_KEYS`).
3. **M5 Tier 5 work in progress**: Four backend unit tests in `portable/tests/test_tier5_backend_gaps.py` remain `xfail` for M5 Tier 5 findings (`T5-02`, `T5-05`, `T5-06`) and do not block the M4 Tiers 1 to 4 E2E gate.
4. **`--frontend start` vs `--frontend static`**: The full `168`-test gate was run in `--frontend static` mode (`portable/web/out/` served by FastAPI), and the `4`-test restart persistence suite was additionally verified in `--frontend start` mode (`20.58s`) to exercise Next.js `/api/*` proxy readiness after `IsolatedWorkspace.restart()`.
