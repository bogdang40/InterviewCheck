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

# The self-contained script also works against the previous running image.
docker exec -i interviewcheck-app-1 python - "$NAME" <<'PY'
from contextlib import closing
import pathlib, sqlite3, sys
source_dir = pathlib.Path("/data")
sources = [source_dir / name for name in ("review.sqlite3", "access.sqlite3")]
if not all(path.is_file() for path in sources):
    raise SystemExit("Both hosted database files must exist before taking a backup.")
out = source_dir / ".backups" / sys.argv[1]
out.mkdir(parents=True, exist_ok=False)
for source in sources:
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src:
        with closing(sqlite3.connect(out / source.name)) as dst:
            src.backup(dst)
            if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise SystemExit("Database backup integrity check failed.")
print("Verified both hosted database backups.")
PY

LOCAL="$DIR/data/.backups/$NAME"
# The uncompressed copy is only a staging step; the archive below is the local copy that is kept.
trap 'rm -rf "$LOCAL"' EXIT
tar -C "$LOCAL" -czf "$LOCAL.tar.gz" .

# Housekeeping runs before the upload so a failing upload cannot stop it.
# Keep a week of local archives; Azure Storage keeps 30 days (lifecycle rule).
find "$DIR/data/.backups" -maxdepth 1 -name '*.tar.gz' -mtime +7 -delete
# Staging folders left by runs that stopped before their cleanup (none is older than a few minutes otherwise).
find "$DIR/data/.backups" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} +
# Database files of versions that failed a rollout (vm-rollout.sh), kept 30 days for inspection.
find "$DIR/data" -mindepth 1 -maxdepth 1 -type d -name '.failed-*' -mtime +30 -exec rm -rf {} +

az login --identity --output none
if ! az storage blob upload --auth-mode login --account-name "$BACKUP_ACCOUNT" \
  --container-name backups --name "$NAME.tar.gz" --file "$LOCAL.tar.gz" --overwrite --output none; then
  echo "backup upload FAILED: $NAME.tar.gz is only on this VM ($LOCAL.tar.gz)" >&2
  exit 1
fi
echo "backup uploaded: $NAME.tar.gz"
