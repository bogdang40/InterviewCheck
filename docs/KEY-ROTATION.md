# Model Secret Key Rotation Playbook

One master key encrypts three columns at rest through `portable/api/secret_box.py`, each with `aad` bound to its row:

- `connected_models.encrypted_api_key` (model API keys, `aad` is the model `id`) in `review.sqlite3`.
- `alert_rules.encrypted_signing_secret` (webhook signing secrets, `aad` is the rule `id`) in `review.sqlite3`.
- `user_totp.secret_enc` (two factor secrets, `aad` is the `user_id`) in the account database. The rotation command finds it at `INTERVIEWCHECK_ACCESS_DB`, or `access.sqlite3` next to the review database, and skips it when that file does not exist.

Key rotation and key status cover all three.

## Envelope Formats and Keyring Resolution

- **`v1:<b64>`**: Legacy envelope using the active master key.
- **`v2:<kid8>:<b64>`**: Key-versioned envelope binding `kid8` (first 8 lowercase hex chars of `SHA-256("ic-kid:" + master_bytes)`) and `aad` inside the HMAC tag.
- **Active key source**: `INTERVIEWCHECK_MODEL_SECRET_KEY` (derived with `scrypt`) takes precedence over the key file (`.model_secret.key` next to `review.sqlite3`, or `INTERVIEWCHECK_MODEL_SECRET_FILE`, mode `0600`).
- **Previous keys**: `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` accepts a single secret or a comma-separated list of retired secrets for fallback decryption during rotation.

## 1. Zero-Downtime Environment Key Rotation (Admin UI or CLI)

Use this procedure when `key_source` is `env` (`INTERVIEWCHECK_MODEL_SECRET_KEY`).

1. **Verify baseline readiness and back up databases**:
   ```sh
   curl -fsS https://<host>/api/readyz
   cd /srv/interviewcheck && set -a && . ./deploy.env && set +a && ./backup.sh pre-key-rotation
   ```
2. **Generate a new master key** (32+ bytes of entropy; never log or commit it):
   ```sh
   python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
   ```
3. **Stage dual-key environment config** in `/srv/interviewcheck/app.env` (mode `0600`):
   - Copy the current `INTERVIEWCHECK_MODEL_SECRET_KEY` value into `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` (append with `,` if an older key is still present).
   - Set `INTERVIEWCHECK_MODEL_SECRET_KEY` to the newly generated value.
4. **Restart the app service and verify `/api/readyz`**:
   ```sh
   cd /srv/interviewcheck && IMAGE=$(cat deployed-image) docker compose --env-file deploy.env up -d --force-recreate app
   curl -fsS http://127.0.0.1:8000/api/readyz
   ```
   At this stage, new model saves encrypt with the new `v2:<kid8>:` key while existing `v1:` and prior `v2:` rows continue decrypting via `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS`.
5. **Re-encrypt stored credentials**:
   - **Option A (Admin UI)**: Open `/admin` -> **Diagnostics** -> **Credential encryption & key rotation**. Confirm `Active key ID` updated, `Previous keys configured >= 1`, and `Needs rotation` matches the pending rows across all three tables. Click **Re-encrypt stored keys**, then **Confirm re-encryption** (`POST /api/admin/models/rotate-keys`).
   - **Option B (CLI inside container or `portable/`)**:
     ```sh
     docker exec -i interviewcheck-app-1 python -m api.key_rotation --db /data/review.sqlite3 --dry-run --json
     docker exec -i interviewcheck-app-1 python -m api.key_rotation --db /data/review.sqlite3 --json
     ```
6. **Verify rotation completion**:
   - In the Admin Diagnostics card (or `GET /api/admin/models/key-status`), verify `needs_rotation_count` is `0` and `current_v2_count` equals `total_with_keys`. The `tables` field gives the same counts for `connected_models`, `alert_rules` and `user_totp`.
   - Run **Test connection** on enabled models in `/admin` -> **Models**, and sign in once with an authenticator code on an account that has two factor authentication enabled.
7. **Retire the previous key**:
   - Remove `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` from `/srv/interviewcheck/app.env` and recreate `app`.
   - Verify `GET /api/readyz` returns `200`, then verify `previous_keys_configured` is `0` via `GET /api/admin/models/key-status` or `/admin` -> **Diagnostics**.

## 2. Local Key-File Rotation (`.model_secret.key`)

Use this procedure when `INTERVIEWCHECK_MODEL_SECRET_KEY` is unset and `key_source` is `file`.

1. **Back up `review.sqlite3` and `.model_secret.key`** to a restricted (`0700`) directory before changing keys.
2. **Dry-run the migration** from `portable/`:
   ```sh
   PYTHONPATH=. .venv/bin/python -m api.key_rotation --db data/review.sqlite3 --dry-run --json
   ```
3. **Rotate the key file and re-encrypt in one atomic flow**:
   ```sh
   PYTHONPATH=. .venv/bin/python -m api.key_rotation --db data/review.sqlite3 --rotate-file-key --json
   ```
   `key_rotation` decrypts every stored secret before writing anything, updates the review tables in one `BEGIN IMMEDIATE` transaction and `user_totp` in a second one on the account database, and atomically replaces `.model_secret.key` via a `0600` temporary file (`os.replace`). It never prints plaintext credentials.
4. **Migrating from an explicit older key**: Pass `--old-key-file /path/to/old.key` or `--old-key-env OLD_SECRET_VAR_NAME` (where `OLD_SECRET_VAR_NAME` is exported in the environment) when moving credentials from a prior file or environment key to the currently configured active key.
5. **Verify permissions and readiness**:
   ```sh
   ls -l portable/data/.model_secret.key
   curl -fsS http://127.0.0.1:8000/api/readyz
   ```
   Confirm `.model_secret.key` mode is `-rw-------` (`0600`) and `/admin` -> **Diagnostics** shows `needs_rotation_count` equal to `0`.

## 3. Atomicity and Failure Recovery

- **Decrypt before write**: Both `POST /api/admin/models/rotate-keys` and `python -m api.key_rotation` decrypt every row in both databases first. If any row raises `SecretBoxError`, nothing is written in either database and `.model_secret.key` stays untouched.
- **One transaction per database**: `connected_models` and `alert_rules` share one review database transaction; `user_totp` has its own account database transaction, which commits first. Rows already under the active key are skipped, so rerunning the same command after any failure finishes the rotation.
- **Partial file key rotation**: With `--rotate-file-key`, if the account database commits but the review database does not, the command reports the partial rotation and keeps the previous key as `.model_secret.key.bak`. Rerun `python -m api.key_rotation --db <review.sqlite3> --old-key-file <path to .model_secret.key.bak>`, confirm `needs_rotation_count` is `0`, then delete the `.bak` file.
- **Recovery on decryption failure**: Verify `INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS` (or `--old-key-file` / `--old-key-env`) includes the key that originally encrypted the failing row. If the original key was lost, restore `review.sqlite3`, `access.sqlite3` and `.model_secret.key` from the pre-rotation backup, or re-enter the affected model API keys and alert signing secrets in `/admin`. A user whose TOTP secret can no longer be decrypted can still sign in with a backup code; the server logs the failure without secret material.
