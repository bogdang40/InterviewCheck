#!/usr/bin/env bash
# Consistent online copies of both SQLite databases, uploaded to Azure Storage.
# Runs on the VM: nightly from interviewcheck-backup.timer, and before each deploy.
# Usage: backup.sh [label]   (label defaults to "nightly")
set -euo pipefail
DIR=/srv/interviewcheck
LABEL=${1:-nightly}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="$STAMP-$LABEL"
: "${BACKUP_ACCOUNT:?BACKUP_ACCOUNT is required}"

# SQLite's backup API inside the running container: safe while the app is writing (WAL mode).
docker exec -i interviewcheck-app-1 python - "$NAME" <<'PY'
import pathlib, sqlite3, sys
out = pathlib.Path("/data/.backups") / sys.argv[1]
out.mkdir(parents=True, exist_ok=True)
for name in ("review.sqlite3", "access.sqlite3"):
    source = pathlib.Path("/data") / name
    if not source.exists():
        continue
    src, dst = sqlite3.connect(source), sqlite3.connect(out / name)
    src.backup(dst)
    src.close(); dst.close()
    with sqlite3.connect(out / name) as check:
        assert check.execute("PRAGMA integrity_check").fetchone()[0] == "ok", name
    print("backed up", name)
PY

LOCAL="$DIR/data/.backups/$NAME"
tar -C "$LOCAL" -czf "$LOCAL.tar.gz" .
az login --identity --output none
az storage blob upload --auth-mode login --account-name "$BACKUP_ACCOUNT" \
  --container-name backups --name "$NAME.tar.gz" --file "$LOCAL.tar.gz" --overwrite --output none
rm -rf "$LOCAL"
# Keep a week of local copies too; Azure Storage keeps 30 days (lifecycle rule).
find "$DIR/data/.backups" -maxdepth 1 -name '*.tar.gz' -mtime +7 -delete
echo "backup uploaded: $NAME.tar.gz"
