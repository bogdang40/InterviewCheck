# Disaster Recovery Runbook

This runbook defines backup, restore, key rotation recovery, and readiness verification procedures for InterviewCheck.

## Persistence Inventory

| Component | Path (VM / Local) | Journal / Format | Contents |
| --- | --- | --- | --- |
| Review database | `/srv/interviewcheck/data/review.sqlite3` | SQLite WAL | Roles, rubrics, sessions, answers, drafts, Trash, `connected_models` |
| Access database | `/srv/interviewcheck/data/access.sqlite3` | SQLite WAL (v8) | Users, sessions, `api_tokens`, subscriptions, rate limits, `audit_log`, `user_totp` |
| Model file key (when env key unset) | `.model_secret.key` (`0600`) | URL-safe base64 (32 bytes) | Master encryption key for `connected_models` credentials |
| Workspace JSON export | Downloadable artifact | UTF-8 JSON + `X-Backup-SHA256` | Roles, sessions, answers, drafts, Trash (excludes secrets and accounts) |

SQLite WAL mode requires local POSIX disk storage. Never place `review.sqlite3` or `access.sqlite3` on a network file share, and never back up an active WAL database with `cp` or `tar` while the service is running.

## 1. Online SQLite WAL Backup

`deploy/backup.sh` runs nightly via `interviewcheck-backup.timer` (07:30 UTC) and before each rollout in `deploy/vm-rollout.sh`. It uses Python `sqlite3.Connection.backup()` inside the running container so active writers in WAL mode do not block or corrupt the snapshot:

```sh
# Inside the running container or against live local files:
python - <<'PY'
import pathlib, sqlite3
out = pathlib.Path("/data/.backups/manual")
out.mkdir(parents=True, exist_ok=True)
for name in ("review.sqlite3", "access.sqlite3"):
    src, dst = sqlite3.connect(f"/data/{name}"), sqlite3.connect(out / name)
    src.backup(dst)
    src.close(); dst.close()
    with sqlite3.connect(out / name) as check:
        assert check.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert check.execute("PRAGMA foreign_key_check").fetchall() == []
PY
```

To trigger a full compressed backup and Azure blob upload on the VM:

```sh
BACKUP_ACCOUNT=<storage-account> deploy/backup.sh manual
```

## 2. Full SQLite Database Restore

Use this procedure when `review.sqlite3`, `access.sqlite3`, or the host disk is lost or corrupted.

1. Stop the application container so no process holds open WAL handles or writes to `/srv/interviewcheck/data`:
   ```sh
   cd /srv/interviewcheck
   IMAGE=$(cat deployed-image) docker compose --env-file deploy.env stop app
   ```
2. Download and extract the target archive from Azure Storage (`backups/<stamp>-<label>.tar.gz`) into a staging directory.
3. Verify SQLite integrity, foreign key consistency, and schema version on both extracted files before moving them into production:
   ```sh
   python3 - <<'PY'
   import sqlite3
   for path, check_ver in (("/tmp/restore/review.sqlite3", False), ("/tmp/restore/access.sqlite3", True)):
       with sqlite3.connect(path) as db:
           db.execute("PRAGMA foreign_keys=ON")
           assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", path
           assert db.execute("PRAGMA foreign_key_check").fetchall() == [], path
           if check_ver:
               assert db.execute("PRAGMA user_version").fetchone()[0] == 8, path
   print("Snapshot verification passed.")
   PY
   ```
4. Remove stale live files and `-wal` / `-shm` sidecars, place the verified files into `/srv/interviewcheck/data`, enforce owner `10001` and mode `0600`, and re-enable WAL mode:
   ```sh
   rm -f /srv/interviewcheck/data/review.sqlite3* /srv/interviewcheck/data/access.sqlite3*
   install -m 0600 -o 10001 -g 10001 /tmp/restore/review.sqlite3 /srv/interviewcheck/data/review.sqlite3
   install -m 0600 -o 10001 -g 10001 /tmp/restore/access.sqlite3 /srv/interviewcheck/data/access.sqlite3
   ```
5. Start the application and verify `/api/readyz` (Section 5).

## 3. Workspace JSON Backup and SHA-256 Restore

Workspace JSON backups recover review records (`roles`, `sessions`, `answers`, `session_drafts`, `session_trash`) into a fresh or compatible `review.sqlite3` without transferring encrypted model credentials or account tables.

1. Download the archive and capture its SHA-256 header:
   ```sh
   curl -sS -D headers.txt -b cookies.txt -o workspace.json https://<site>/api/backups/workspace
   grep -i '^X-Backup-SHA256:' headers.txt
   sha256sum workspace.json
   ```
2. Preview the restore against the target database. The API checks `X-Backup-SHA256`, validates schema and finding evidence via `backup_validation.verify_records`, and returns a preview `fingerprint`:
   ```sh
   SHA=$(sha256sum workspace.json | awk '{print $1}')
   curl -sS -X POST -b cookies.txt \
     -H "X-InterviewCheck: 1" -H "X-Backup-SHA256: $SHA" \
     --data-binary @workspace.json https://<site>/api/backups/preview
   ```
3. Apply the restore using both `X-Backup-Preview` (set to the verified SHA-256 `fingerprint`) and `X-Backup-SHA256`. Conflicting IDs return `409` and invalid evidence or checksums return `422` / `409` without partial writes:
   ```sh
   curl -sS -X POST -b cookies.txt \
     -H "X-InterviewCheck: 1" -H "X-Backup-Preview: $SHA" -H "X-Backup-SHA256: $SHA" \
     --data-binary @workspace.json https://<site>/api/backups/restore
   ```
4. Re-register or restore `connected_models` credentials if rebuilding from JSON alone, because `encrypted_api_key` values are intentionally excluded from workspace JSON exports.

## 4. Model Secret Key Rotation Recovery

Model API keys in `connected_models` use `secret_box` `v1:` or `v2:<key_id>:` authenticated envelopes tied to `aad=model_id`.

1. If restoring a database encrypted with an older master key, set the active key in `INTERVIEWCHECK_MODEL_SECRET_KEY` and list retired key(s) in `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` (comma-separated) before starting the service.
2. Run a non-mutating dry run first to verify every stored credential decrypts cleanly:
   ```sh
   cd /app/portable
   PYTHONPATH=. python -m api.key_rotation --db /data/review.sqlite3 --dry-run --json
   ```
   When recovering from retired key files or env keys directly via CLI, pass `--old-key-file <path>` or `--old-key-env <secret>`.
3. Execute the atomic rotation to re-encrypt all rows into `v2:<active_key_id>:` envelopes inside a single SQLite transaction:
   ```sh
   PYTHONPATH=. python -m api.key_rotation --db /data/review.sqlite3 --json
   ```
   To rotate a file-backed `.model_secret.key`, pass `--rotate-file-key`; the new key file is written atomically with `0600` permissions.
4. Remove `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` once `GET /api/admin/models/key-status` (or `key_rotation.key_status`) reports `"needs_rotation_count": 0`.

## 5. Health and Readiness Verification

Always check both probes after restore, migration, or key rotation:

- `GET /api/healthz`: returns `200 {"ok": true, "service": "interviewcheck-api"}` when the API process is alive.
- `GET /api/readyz`: returns `200 {"ok": true, "checks": {"review_db": "ok", "access_db": "ok", "secret_box": "ok", "web_bundle": "ok"}}` (or `"access_db": "skipped"` when `INTERVIEWCHECK_ACCESS_MODE` is not `embedded`). Any `503` indicates at least one failed subsystem:
  - `review_db: "error"`: missing file, non-WAL journal mode, or missing core tables (`sessions`, `roles`, `connected_models`).
  - `access_db: "error"`: missing file, invalid schema, or `PRAGMA user_version != 8`.
  - `secret_box: "error"`: unreadable key file, permissions broader than `0600`, or invalid key bytes.
  - `web_bundle: "missing"`: `portable/web/out/index.html` is absent.

## 6. Automated End-to-End DR Drill

Run `scripts/dr_drill.py` regularly in CI and before major schema or deployment changes. The drill seeds `review.sqlite3` and `access.sqlite3` (v8), executes concurrent WAL reader/writer stress while capturing online `sqlite3.Connection.backup()` snapshots and workspace JSON exports, simulates DB corruption and loss, restores both databases, rotates `v1:` and `v2:` model credentials, validates workspace JSON restore into a clean DB, and verifies `/api/healthz` and `/api/readyz`.

```sh
PYTHONPATH=portable portable/.venv/bin/python scripts/dr_drill.py --json
```

Optional `--work-dir <path>` keeps drill artifacts in a specified directory instead of a temporary folder. The command exits `0` with `"ok": true` when every check passes and emits zero secrets or plaintext API keys; any check failure returns a non-zero exit code.
