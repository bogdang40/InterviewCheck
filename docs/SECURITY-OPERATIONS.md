# Security Operations Runbook

Operational procedures for InterviewCheck production controls introduced in M17 through M19.
All administrative API mutations require an authenticated admin session (`ic_access` cookie) and the `X-InterviewCheck: 1` header.

## 1. Model Circuit Breakers and SLA Triage

`portable/api/model_circuit.py` tracks per-model failure streaks in `review.sqlite3` (`model_circuit_state`) and latency percentiles in `model_health_checks`.

- **States:** `closed` (normal routing), `open` (skipped during fallback until `next_retry_at`), and `half_open` (allows one probe after cooldown).
- **Default policy:** `consecutive_threshold = 3`, `cooldown_seconds = 60`, `sla_target_ms = 2500`.
- **Failover behavior:** `_run_chain` skips open circuits to the next configured fallback model. If all candidates are open, the API returns HTTP `503` with a `Retry-After` header.

### Triage workflow

1. Query fleet SLA and circuit state:
   ```sh
   curl -fsS -b cookies.txt https://$SITE_ADDRESS/api/admin/models/sla | jq .
   ```
   Inspect `p50_latency_ms`, `p95_latency_ms`, `p99_latency_ms`, `error_rate_pct`, `sla_compliant`, and `circuit.last_failure_reason`.
2. Adjust thresholds if a provider exhibits transient latency spikes (`consecutive_threshold` `1..20`, `cooldown_seconds` `5..3600`, `sla_target_ms` `100..60000`):
   ```sh
   curl -fsS -X PATCH -b cookies.txt -H "X-InterviewCheck: 1" \
     -H "Content-Type: application/json" \
     -d '{"consecutive_threshold": 5, "cooldown_seconds": 120, "sla_target_ms": 4000}' \
     https://$SITE_ADDRESS/api/admin/models/$MODEL_ID/circuit
   ```
3. Verify upstream provider health via `POST /api/admin/models/$MODEL_ID/probe`, then reset the circuit manually (logged as `admin.model.circuit_reset`):
   ```sh
   curl -fsS -X POST -b cookies.txt -H "X-InterviewCheck: 1" \
     https://$SITE_ADDRESS/api/admin/models/$MODEL_ID/circuit/reset
   ```

## 2. Versioned Prompt Governance and Rollback

`portable/api/prompt_templates.py` manages the five system prompt slots in `prompt_templates` and immutable revisions in `prompt_template_versions`:
`question_planning`, `reference_spoken`, `reference_talking_points`, `reference_worked_example`, and `judge_rubric`.

- Untrusted candidate text remains wrapped by `prompt_framing.frame_instructions` and `untrusted_json_prompt`. Admin template edits cannot disable framing.
- Updates strip control characters and enforce optimistic concurrency via `expected_version` (HTTP `409` on mismatch).

### Rollback procedure

1. Inspect version history and unified diffs (`difflib.unified_diff`) for a slot:
   ```sh
   curl -fsS -b cookies.txt https://$SITE_ADDRESS/api/admin/prompts/judge_rubric/versions | jq .
   ```
2. Roll back to a known good `target_version` by supplying the current `expected_version` (creates immutable version `N + 1` and logs `admin.prompt.rollback`):
   ```sh
   curl -fsS -X POST -b cookies.txt -H "X-InterviewCheck: 1" \
     -H "Content-Type: application/json" \
     -d '{"target_version": 1, "expected_version": 3, "change_note": "Revert noisy rubric phrasing"}' \
     https://$SITE_ADDRESS/api/admin/prompts/judge_rubric/rollback
   ```

## 3. TOTP 2FA Recovery and Backup Codes

`access.sqlite3` (schema v8) stores encrypted RFC 6238 HMAC-SHA1 secrets in `user_totp` (`aad=user_id`) and eight single-use `XXXX-XXXX` SHA-256 digests in `user_backup_codes`.

- When 2FA is active and `totpCode` is omitted at login, auth returns HTTP `401` with `error.code = "totp_required"` and header `X-InterviewCheck-TOTP: required`.
- Invalid TOTP or backup codes increment IP and per-email lockout windows.

### Recovery workflows

1. **User retains a backup code:** Sign in with `totpCode` set to an unused `XXXX-XXXX` code (atomically marks `used_at`), then open `/account/` to regenerate codes (`POST /api/integrations/security/totp/backup-codes/regenerate`) or disable and re-enroll TOTP.
2. **User lost authenticator and all backup codes:**
   - Verify operator or user identity out-of-band before touching `access.sqlite3`.
   - Back up `access.sqlite3`, then remove the user's rows in `user_totp` and `user_backup_codes` in a single transaction on the VM, and require immediate TOTP re-enrollment on next login.
   - Do not weaken `account_auth.py` lockout limits or bypass TOTP checks in application code.

## 4. Tamper-Evident Audit Hash-Chain Verification

Both `audit_log` (`access.sqlite3`, Node and Python) and `model_audit` (`review.sqlite3`) compute a sequential SHA-256 chain inside the write transaction:

```text
payload = "{prev_hash or 'GENESIS'}|{at}|{actor_user_id or ''}|{action}|{target_user_id or ''}|{details or ''}"
entry_hash = sha256(payload.encode("utf-8")).hexdigest()
```

### Verification commands

Run all three verification endpoints (`Cache-Control: no-store`, admin required):

```sh
curl -fsS -b cookies.txt https://$SITE_ADDRESS/v1/admin/audit/verify
curl -fsS -b cookies.txt https://$SITE_ADDRESS/api/integrations/admin/audit/verify
curl -fsS -b cookies.txt https://$SITE_ADDRESS/api/admin/audit/verify
```

Expected response: `{"ok": true, "verifiedCount": ..., "legacyUnchainedCount": ..., "firstBrokenId": null, "headHash": "..."}`.

### Response when `ok` is `false`

1. Stop writes or snapshot `review.sqlite3` and `access.sqlite3` to a read-only forensic copy immediately.
2. Inspect rows around `firstBrokenId` to distinguish unauthorized SQLite mutation from an interrupted legacy migration.
3. Rotate session/model encryption keys (`INTERVIEWCHECK_MODEL_SECRET_KEY`, admin credentials, and connected provider API keys).
4. Restore databases from the latest verified pre-tamper archive in `backups/` after fixing the host compromise vector.

## 5. CSP Violation Triage

HTML document responses include `report-uri /api/csp-report` (`portable/api/security_headers.py`). Static assets (`_STATIC_ASSET_CSP`) and API JSON (`_API_CSP`) keep strict `default-src 'none'` without changing existing headers.

- `POST /api/csp-report` accepts `application/csp-report` and `application/reports+json`, caps bodies at `8192` bytes, enforces `60/min/client` rate limits without requiring `X-InterviewCheck: 1`, strips query/fragment strings, and stores up to 500 records in `csp_violations`.

### Triage workflow

1. List and clear violation records as an admin:
   ```sh
   curl -fsS -b cookies.txt https://$SITE_ADDRESS/api/admin/security/csp-reports | jq .
   curl -fsS -X DELETE -b cookies.txt -H "X-InterviewCheck: 1" \
     https://$SITE_ADDRESS/api/admin/security/csp-reports
   ```
2. Classify `blocked-uri` and `violated-directive`:
   - Browser extension schemes (`chrome-extension://`, `moz-extension://`): noise; no policy change.
   - `script-src` on first-party routes: verify `portable/web/out/` matches the running container image and `_script_hashes` cache is fresh. Never add `'unsafe-inline'` to `script-src`.
   - `style-src` on `/api/sessions/{sid}/print`: confirm `exports.PRINT_STYLE_HASH` matches `exports.STYLE`.

## 6. Deployment Config Validation and Print Redaction

Run the deployment configuration validator in CI and before production rollouts:

```sh
python3 scripts/check_deploy_config.py --json
# --strict-prod checks app.env only through --env-file; without it, it checks this shell's environment.
python3 scripts/check_deploy_config.py --strict-prod --env-file <path to the deployment's app.env>
```

The validator checks:
- `deploy/Caddyfile`: `max_size 26MB`, `header_up X-InterviewCheck-Client-IP`, `-Server`, `X-Frame-Options "DENY"`.
- `deploy/compose.yml`: `network_mode: host`, `env_file: [app.env]`.
- `deploy/Dockerfile`: non-root `USER app`, `HEALTHCHECK`.
- `deploy/vm-rollout.sh`: `set -euo pipefail` and pre-deploy backup execution.

For blind panel calibration, export printable reports with `redact_candidate=true` on `GET /api/sessions/{sid}/print`: candidate name becomes `Candidate [Redacted]`, raw answers/excerpts/legacy JSON are omitted, and dispositions, passage counts, and rubric scorecard summaries remain intact under `Cache-Control: no-store`.
