#!/usr/bin/env bash
# Runs ON the VM as root through `az vm run-command` (see .github/workflows/deploy.yml).
# The workflow prepends these variables before this file:
#   IMAGE           full image reference in ACR, tagged with the commit
#   ACR             registry name (without .azurecr.io)
#   SITE_ADDRESS    public host name Caddy serves
#   BACKUP_ACCOUNT  storage account for nightly database backups
#   COMPOSE_B64, CADDY_B64, BACKUP_B64  base64 of deploy/compose.yml, deploy/Caddyfile, deploy/backup.sh
# Success means: the new app is healthy, Caddy runs the new Caddyfile, and HTTPS through Caddy serves
# the app. Any failure after the new app starts rolls back (see rollback). Prints ROLLOUT_OK on success;
# the workflow fails without it.
# run-command starts scripts with /bin/sh; rerun this whole file (variables included) under bash.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail
DIR=/srv/interviewcheck
cd "$DIR"

log() { echo "[rollout] $*"; }
compose() { local image=$1; shift; IMAGE="$image" SITE_ADDRESS="$SITE_ADDRESS" docker compose "$@"; }

for name in IMAGE ACR SITE_ADDRESS BACKUP_ACCOUNT COMPOSE_B64 CADDY_B64 BACKUP_B64; do
  [ -n "${!name:-}" ] || { echo "missing $name"; exit 1; }
done
[ -f app.env ] || { echo "app.env is missing: run deploy/provision-azure.sh first"; exit 1; }

echo "$COMPOSE_B64" | base64 -d > compose.yml
echo "$BACKUP_B64" | base64 -d > backup.sh && chmod 755 backup.sh
# Caddy reads its Caddyfile only when it starts or reloads. The new one waits in Caddyfile.next until
# the new app is healthy (apply_caddyfile); only a first deploy, with no Caddyfile yet, starts on it.
echo "$CADDY_B64" | base64 -d > Caddyfile.next
[ -f Caddyfile ] || cp Caddyfile.next Caddyfile
mkdir -p data && chown 10001:10001 data
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
CURRENT_ID=$(docker inspect --format '{{.Image}}' interviewcheck-app-1 2>/dev/null || true)
log "current: ${CURRENT:-none} (${CURRENT_ID:-no image}); new: $IMAGE"
if [ -z "$CURRENT" ] && { [ -e data/review.sqlite3 ] || [ -e data/access.sqlite3 ]; }; then
  log "existing databases have no identified application container; recover the previous container and verify a backup before retrying"
  exit 1
fi
# Roll back to the exact image that was running: a rebuild of the same commit can move CURRENT's tag.
ROLLBACK_IMAGE=""
if [ -n "$CURRENT_ID" ]; then
  ROLLBACK_IMAGE=interviewcheck-web:previous
  docker tag "$CURRENT_ID" "$ROLLBACK_IMAGE"
fi

log "pulling"
compose "$IMAGE" pull --quiet

# Keep a copy of the databases from just before the new version starts (schema upgrades).
# PRE is that copy's local archive; a rollback puts it back (see below).
PRE=""
if [ -n "$CURRENT" ]; then
  marker=$(mktemp)
  if ! BACKUP_ACCOUNT="$BACKUP_ACCOUNT" ./backup.sh pre-deploy; then
    rm -f "$marker"
    log "pre-deploy backup failed; the current application remains selected"
    exit 1
  fi
  PRE=$(find data/.backups -maxdepth 1 -name '*-pre-deploy.tar.gz' -newer "$marker" 2>/dev/null | sort | tail -1 || true)
  rm -f "$marker"
fi

wait_healthy() {  # up to about three minutes
  for _ in $(seq 1 45); do
    state=$(docker inspect --format '{{.State.Health.Status}}' interviewcheck-app-1 2>/dev/null || echo missing)
    [ "$state" = healthy ] && return 0
    sleep 4
  done
  return 1
}

caddy_cmd() { compose "$IMAGE" exec -T caddy caddy "$1" --config /etc/caddy/Caddyfile --adapter caddyfile; }

CADDY_SWAPPED=""
apply_caddyfile() {
  cmp -s Caddyfile.next Caddyfile && return 0
  log "the Caddyfile changed; validating and reloading Caddy (previous file: Caddyfile.previous)"
  cp -p Caddyfile Caddyfile.previous || return 1
  # Write in place: the container's single file bind mount follows this inode, not the path.
  cat Caddyfile.next > Caddyfile || return 1
  CADDY_SWAPPED=1
  caddy_cmd validate && caddy_cmd reload
}

restore_caddyfile() {
  [ -n "$CADDY_SWAPPED" ] || return 0
  log "restoring the previous Caddyfile"
  cat Caddyfile.previous > Caddyfile
  caddy_cmd reload || log "Caddy did not reload the previous Caddyfile; check it by hand"
}

edge_serves() {  # HTTPS through the local Caddy, with the real certificate and host name
  for _ in $(seq 1 10); do
    if curl -fsS -o /dev/null --max-time 10 --resolve "$SITE_ADDRESS:443:127.0.0.1" "https://$SITE_ADDRESS/api/readyz" &&
       curl -fsS -o /dev/null --max-time 10 --resolve "$SITE_ADDRESS:443:127.0.0.1" "https://$SITE_ADDRESS/"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

rollback() {
  log "$1; last log lines:"
  docker logs --tail 40 interviewcheck-app-1 2>&1 || true
  restore_caddyfile
  if [ -n "$ROLLBACK_IMAGE" ]; then
    # The failed version may have upgraded the database schema before it stopped. The previous
    # version must not run on that, so put back the copy taken just before the new version started.
    # The failed version's files are kept in data/.failed-<time> (backup.sh removes them after 30 days).
    compose "$ROLLBACK_IMAGE" stop app || true
    if [ -n "$PRE" ]; then
      kept="data/.failed-$(date -u +%Y%m%dT%H%M%SZ)"
      log "restoring the databases from $PRE (failed version's files: $kept)"
      mkdir -p "$kept"
      find data -maxdepth 1 \( -name 'review.sqlite3*' -o -name 'access.sqlite3*' \) -exec mv {} "$kept"/ \;
      tar -C data -xzf "$PRE" --wildcards './*.sqlite3'
      chown 10001:10001 data/*.sqlite3 && chmod 600 data/*.sqlite3
    else
      log "no pre-deploy backup from this rollout; the previous version starts on the current files"
    fi
    log "rolling back to $CURRENT ($CURRENT_ID)"
    compose "$ROLLBACK_IMAGE" up -d
    if wait_healthy; then log "previous version is healthy again"; else log "previous version is NOT healthy"; fi
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
  fi
  exit 1
}

log "starting"
compose "$IMAGE" up -d --remove-orphans

wait_healthy || rollback "new version is not healthy"
apply_caddyfile || rollback "Caddy did not accept the new Caddyfile"
edge_serves || rollback "https://$SITE_ADDRESS did not answer through Caddy"

echo "$IMAGE" > deployed-image
# Each image is about 1.7 GB on a 30 GB disk: keep only this one and the previous one.
# Older images stay in the registry and can be pulled again.
docker images --format '{{.Repository}}:{{.Tag}}' | grep -F "${IMAGE%:*}:" \
  | grep -vxF -e "$IMAGE" -e "${CURRENT:-$IMAGE}" | xargs -r docker rmi >/dev/null 2>&1 || true
docker image prune -f >/dev/null 2>&1 || true
log "healthy: $IMAGE"
echo ROLLOUT_OK
