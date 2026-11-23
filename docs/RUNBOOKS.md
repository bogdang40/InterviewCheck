# Production Operational Runbooks

These runbooks cover health probes, SQLite WAL backups, and model runtime incidents for the InterviewCheck portable deployment (`portable/api/` and `deploy/`). See [DEPLOY.md](DEPLOY.md) for host layout and [KEY-ROTATION.md](KEY-ROTATION.md) for credential rotation.

## 1. Health and Readiness Probes

| Endpoint | Auth | Purpose | Expected Status |
| --- | --- | --- | --- |
| `GET /api/healthz` | None | Fast process liveness check | `200` (`{"ok":true,"service":"interviewcheck-api"}`) |
| `GET /api/readyz` | None | Deep dependency readiness check | `200` when ready, `503` when degraded |
| `GET /api/health` | None | Legacy session table probe (preserved) | `200` (`{"ok":true}`) |

Both `/api/healthz` and `/api/readyz` return `Cache-Control: no-store`. `/api/readyz` exposes only minimized status labels (`ok`, `error`, `skipped`, `missing`) and never returns file paths, stack traces, or key IDs.

### Verification Commands

```sh
curl -fsS http://127.0.0.1:8000/api/healthz
curl -i -sS http://127.0.0.1:8000/api/readyz
```

### Triage on `/api/readyz` `503`

```json
{"ok":false,"checks":{"review_db":"ok","access_db":"ok","secret_box":"error","web_bundle":"ok"}}
```

1. **`review_db: "error"`**: Confirm `review.sqlite3` exists, is owned by UID `10001` in Docker, has `PRAGMA journal_mode` set to `wal`, and contains `sessions`, `roles`, and `connected_models`. Run `sqlite3 /srv/interviewcheck/data/review.sqlite3 "PRAGMA integrity_check;"`.
2. **`access_db: "error"`**: Applies when `INTERVIEWCHECK_ACCESS_MODE=embedded` (`access_db` is `skipped` otherwise). Verify `access.sqlite3` is readable, separate from `review.sqlite3`, passes `PRAGMA integrity_check`, and has `PRAGMA user_version` equal to `account_db.VERSION` (`8`).
3. **`secret_box: "error"`**: Check `INTERVIEWCHECK_MODEL_SECRET_KEY` in `app.env`, or check `.model_secret.key` (or `INTERVIEWCHECK_MODEL_SECRET_FILE`). On POSIX hosts, `.model_secret.key` must have mode `0600` (no group or world permissions) and contain a valid 32-byte URL-safe base64 key.
4. **`web_bundle: "missing"`**: Verify either `portable/web/out/index.html` (static export via `npm --prefix portable/web run export`) or `portable/web/.next-server/routes-manifest.json` (Next.js `start` runtime via `node portable/web-runtime.mjs build`) is present in the deployed image.

## 2. SQLite WAL Backup and Restore

Both `review.sqlite3` and `access.sqlite3` run in SQLite `WAL` mode on local VM disk (`/srv/interviewcheck/data/`). Never use plain `cp` on a live WAL database, and never place WAL databases on network file shares.

### Online Host SQLite Backup and Restore (`deploy/backup.sh`)

`interviewcheck-backup.timer` (07:30 UTC daily) and `deploy/vm-rollout.sh` (`pre-deploy`) call `sqlite3.connect(src).backup(dst)` inside `interviewcheck-app-1`, verify `PRAGMA integrity_check == ok`, and upload `<UTC>-<label>.tar.gz` to Azure Storage (`BACKUP_ACCOUNT`, container `backups`).

Manual backup on the VM:

```sh
cd /srv/interviewcheck && set -a && . ./deploy.env && set +a && ./backup.sh manual
```

Full database restore on the VM:

1. Stop the app container so no writers hold WAL locks:
   ```sh
   cd /srv/interviewcheck && IMAGE=$(cat deployed-image) docker compose --env-file deploy.env stop app
   ```
2. Download and unpack the target archive from Azure Storage (`backups/<name>.tar.gz`) into a staging folder and run `PRAGMA integrity_check;` on both `.sqlite3` files.
3. Move any existing `review.sqlite3`, `access.sqlite3`, `-wal`, and `-shm` files out of `/srv/interviewcheck/data/` into a quarantine directory.
4. Copy the verified `.sqlite3` files into `/srv/interviewcheck/data/`, set `chown 10001:10001` and `chmod 0600`, then start the app:
   ```sh
   cd /srv/interviewcheck && IMAGE=$(cat deployed-image) docker compose --env-file deploy.env up -d app
   ```
5. Confirm `GET /api/readyz` returns `200` and `{"ok":true,...}`.

### Portable Workspace JSON Backup with `X-Backup-SHA256`

`/api/backups/workspace` exports roles, sessions, drafts, answers, and trash state as JSON, excluding `connected_models` encrypted keys, `model_usage_daily`, and `access.sqlite3`.

1. **Export and record checksum**:
   ```sh
   curl -fsS -D headers.txt -b cookies.txt -o workspace.json https://<host>/api/backups/workspace
   grep -i '^x-backup-sha256:' headers.txt
   sha256sum workspace.json
   ```
2. **Preview with checksum verification**:
   ```sh
   SHA=$(sha256sum workspace.json | awk '{print $1}')
   curl -fsS -b cookies.txt -H "X-InterviewCheck: 1" -H "X-Backup-SHA256: $SHA" \
     --data-binary @workspace.json https://<host>/api/backups/preview
   ```
   A digest mismatch returns `409`; an invalid hex header returns `422`. Save the returned `fingerprint` value.
3. **Restore inside one atomic transaction**:
   ```sh
   curl -fsS -b cookies.txt -H "X-InterviewCheck: 1" \
     -H "X-Backup-SHA256: $SHA" -H "X-Backup-Preview: $FINGERPRINT" \
     --data-binary @workspace.json https://<host>/api/backups/restore
   ```
   If `conflicts` is non-empty or the payload changed since preview, the API returns `409` with zero database writes. `PRAGMA foreign_key_check` runs before commit.

## 3. Provider Outage Playbook

`model_execution.py` retries transient `429`, `502`, `503`, and `504` responses up to `max_retries` (clamped `0..3`), then fails over through enabled candidates for the capability sorted by `is_default DESC, fallback_priority ASC`.

1. Open `/admin` -> **Diagnostics** tab and **Models** -> **Health history** to inspect failing models, P95 latency, and `last_error`.
2. In `/admin` -> **Models**, run **Test capability chain** (`POST /api/admin/models/simulate-chain`) for the affected capability to see the active fallback order and any skipped models without issuing live provider calls.
3. Disable the failing model (**Disable**) or promote a healthy secondary model (`is_default: true` or lower `fallback_priority`), then click **Test connection** on the replacement.
4. If all registry models for a capability are disabled, verify environment fallbacks (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPGRAM_API_KEY`) in `/srv/interviewcheck/app.env` and recreate `app` if updated.

## 4. SSRF Block Incident Playbook

`ssrf_guard.py` permits custom endpoints only for `azure_openai` (`*.openai.azure.com` or `*.cognitiveservices.azure.com` with empty path) and `openai_compatible`. Endpoints must use `https://` on port `443`, omit credentials, query strings, and fragments, and resolve via DNS to global public IP addresses. `SafeAsyncTransport` pins outbound TCP connections to the validated IP. SSRF rejections (`400`) abort execution immediately and do not fail over.

1. Read `last_error` on the model card in `/admin` or the `admin.model.probe` audit event.
2. Verify DNS from the host resolves only to public IPs and not loopback, RFC1918 private ranges, link-local (`169.254.0.0/16`), or `.local`/`.internal` suffixes:
   ```sh
   dig +short <endpoint-hostname>
   ```
3. Fix the endpoint URL in `/admin` -> **Configure** (`PATCH /api/admin/models/{id}`) to a compliant public `https://` hostname, then run **Test connection**.
4. Treat repeated unexpected private-IP DNS answers on a configured hostname as a potential DNS rebinding or compromise event and disable the model until verified.

## 5. Budget and Quota Incident Playbook

Three independent limits can trigger `429` or candidate skipping:

| Limit | Scope | Source / Diagnostic Signal |
| --- | --- | --- |
| Model `rpm_limit` | Per model, 60s window | `model_execution.ModelQuotaLimiter` (`Retry-After` header, fails over to next model) |
| Daily token / monthly USD cap | Per model, UTC day/month | `model_usage_daily` (`daily_token_limit_exceeded` / `monthly_cost_limit_exceeded` in simulator; `429` when chain exhausted) |
| API route rate limit | Per client IP, 60s window | `rate_limit.py` (`ADMIN_READ` 120, `ADMIN_WRITE` 40, `ADMIN_PROBE` 15, `AI_REQUEST` 20, `INTEGRATION_REMOTE` 30, `BILLING_ACTION` 20) |

### Remediation

1. Open `/admin` -> **Diagnostics** to inspect **Per-model token and cost usage** bars and **Daily tokens & spend** totals.
2. Run **Test capability chain** to confirm whether a candidate is skipped for `daily_token_limit_exceeded`, `monthly_cost_limit_exceeded`, or `rpm_remaining == 0`.
3. To restore capacity immediately, enable or add a fallback model for the capability, or raise `daily_token_limit`, `monthly_cost_limit_usd`, or `rpm_limit` in **Configure**.
4. For `rate_limit.py` `429` bursts behind Caddy, confirm `INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1` and `X-InterviewCheck-Client-IP` so users do not share one loopback rate-limit bucket.
