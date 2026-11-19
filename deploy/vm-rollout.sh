#!/usr/bin/env bash
# Runs ON the VM as root through `az vm run-command` (see .github/workflows/deploy.yml).
# The workflow prepends these variables before this file:
#   IMAGE           full image reference in ACR, tagged with the commit
#   ACR             registry name (without .azurecr.io)
#   SITE_ADDRESS    public host name Caddy serves
#   BACKUP_ACCOUNT  storage account for nightly database backups
#   COMPOSE_B64, CADDY_B64, BACKUP_B64  base64 of deploy/compose.yml, deploy/Caddyfile, deploy/backup.sh
# Prints ROLLOUT_OK on success; the workflow fails without it.
# run-command starts scripts with /bin/sh; rerun this whole file (variables included) under bash.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail
DIR=/srv/interviewcheck
cd "$DIR"

log() { echo "[rollout] $*"; }

for name in IMAGE ACR SITE_ADDRESS BACKUP_ACCOUNT COMPOSE_B64 CADDY_B64 BACKUP_B64; do
  [ -n "${!name:-}" ] || { echo "missing $name"; exit 1; }
done
[ -f app.env ] || { echo "app.env is missing: run deploy/provision-azure.sh first"; exit 1; }

echo "$COMPOSE_B64" | base64 -d > compose.yml
echo "$CADDY_B64" | base64 -d > Caddyfile
echo "$BACKUP_B64" | base64 -d > backup.sh && chmod 755 backup.sh
mkdir -p data backups && chown 10001:10001 data
cat > deploy.env <<EOF
SITE_ADDRESS=$SITE_ADDRESS
BACKUP_ACCOUNT=$BACKUP_ACCOUNT
EOF

# Nightly backup timer (idempotent).
cat > /etc/systemd/system/interviewcheck-backup.service <<'EOF'
[Unit]
Description=Back up the InterviewCheck databases to Azure Storage
After=docker.service
[Service]
Type=oneshot
EnvironmentFile=/srv/interviewcheck/deploy.env
ExecStart=/srv/interviewcheck/backup.sh
EOF
cat > /etc/systemd/system/interviewcheck-backup.timer <<'EOF'
[Unit]
Description=Nightly InterviewCheck backup
[Timer]
OnCalendar=*-*-* 07:30:00 UTC
RandomizedDelaySec=15m
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now interviewcheck-backup.timer >/dev/null

log "signing in to $ACR with the VM identity"
az login --identity --output none
az acr login --name "$ACR" --output none

CURRENT=$(docker inspect --format '{{.Config.Image}}' interviewcheck-app-1 2>/dev/null || true)
log "current: ${CURRENT:-none}; new: $IMAGE"

log "pulling"
IMAGE="$IMAGE" SITE_ADDRESS="$SITE_ADDRESS" docker compose pull --quiet

# Keep a copy of the databases from just before the new version starts (schema upgrades).
if [ -n "$CURRENT" ]; then
  if ! BACKUP_ACCOUNT="$BACKUP_ACCOUNT" ./backup.sh pre-deploy; then
    log "pre-deploy backup failed; the current application remains selected"
    exit 1
  fi
fi

log "starting"
IMAGE="$IMAGE" SITE_ADDRESS="$SITE_ADDRESS" docker compose up -d --remove-orphans

healthy=""
for _ in $(seq 1 45); do
  state=$(docker inspect --format '{{.State.Health.Status}}' interviewcheck-app-1 2>/dev/null || echo missing)
  if [ "$state" = healthy ]; then healthy=1; break; fi
  sleep 4
done

if [ -z "$healthy" ]; then
  log "new version is not healthy; last log lines:"
  docker logs --tail 40 interviewcheck-app-1 2>&1 || true
  if [ -n "$CURRENT" ]; then
    log "rolling back to $CURRENT"
    IMAGE="$CURRENT" SITE_ADDRESS="$SITE_ADDRESS" docker compose up -d
  fi
  exit 1
fi

echo "$IMAGE" > deployed-image
docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
log "healthy: $IMAGE"
echo ROLLOUT_OK
