#!/bin/bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "Usage: deploy-app.sh BUILD_OUTPUT DEPLOY_TARGET USE_ADHOC_SIGNING ENTITLEMENTS Debug|Release" >&2
  exit 2
fi
BUILD_OUTPUT="$1"
DEPLOY_TARGET="$2"
USE_ADHOC_SIGNING="$3"
ENTITLEMENTS="$4"
BUILD_CONFIGURATION="$5"
case "$USE_ADHOC_SIGNING:$BUILD_CONFIGURATION" in
  0:Debug|1:Debug|0:Release|1:Release) ;;
  *) echo "Invalid deployment signing mode or configuration." >&2; exit 2 ;;
esac

echo "=== Staging $BUILD_CONFIGURATION deployment ==="
DEPLOY_DIR="$(dirname "$DEPLOY_TARGET")"
mkdir -p "$DEPLOY_DIR"
DEPLOY_LOCK="$DEPLOY_DIR/.memanager-deployment.lock"
DEPLOY_LOCK_OWNED=0
STAGING_DIR=""
PREVIOUS_APP=""
DEPLOYMENT_COMPLETE=0

rename_bundle() {
  # Unlike mv, rename never nests the source inside an existing directory.
  # A competing nonempty app bundle remains intact, even if it ignores our lock.
  python3 - "$1" "$2" <<'PY'
import os
import sys
os.rename(sys.argv[1], sys.argv[2])
PY
}

cleanup_deployment() {
  local result=$?
  local preserve_staging=0
  trap - EXIT
  trap '' INT TERM
  if [ "$DEPLOYMENT_COMPLETE" -eq 0 ] && { [ -e "$PREVIOUS_APP" ] || [ -L "$PREVIOUS_APP" ]; }; then
    if [ ! -e "$DEPLOY_TARGET" ] && [ ! -L "$DEPLOY_TARGET" ] && rename_bundle "$PREVIOUS_APP" "$DEPLOY_TARGET"; then
      echo "Previous deployment restored." >&2
    else
      echo "ERROR: Previous deployment preserved at: $PREVIOUS_APP" >&2
      echo "Restore it to $DEPLOY_TARGET before retrying deployment." >&2
      preserve_staging=1
      result=1
    fi
  fi
  if [ "$preserve_staging" -eq 0 ] && [ -n "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR" || result=1
  fi
  if [ "$DEPLOY_LOCK_OWNED" -eq 1 ]; then
    rmdir "$DEPLOY_LOCK" || result=1
  fi
  exit "$result"
}
trap cleanup_deployment EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Debug and release deployments share this lock across checkouts.
# Keep it through rollback so a failed deployment cannot replace another release.
if ! mkdir "$DEPLOY_LOCK"; then
  echo "ERROR: Another deployment owns $DEPLOY_LOCK. Retry after it finishes." >&2
  echo "If the previous process was killed, remove the lock only after confirming it stopped." >&2
  exit 1
fi
DEPLOY_LOCK_OWNED=1
STAGING_DIR="$(mktemp -d "$DEPLOY_DIR/.memanager-release.XXXXXX")"
STAGED_APP="$STAGING_DIR/memanager.app"
PREVIOUS_APP="$STAGING_DIR/previous.app"

ditto "$BUILD_OUTPUT" "$STAGED_APP"

if [ "$USE_ADHOC_SIGNING" -eq 1 ]; then
  echo "=== Applying ad-hoc signature ==="
  if [ "$BUILD_CONFIGURATION" = Release ]; then
    # Keep nested code signatures and apply the release app's entitlements.
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$STAGED_APP"
  else
    codesign --force --deep --sign - "$STAGED_APP"
  fi
fi

echo "=== Verifying staged deployment ==="
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

echo "=== Deploying to ~/.memanager ==="
if [ -e "$DEPLOY_TARGET" ] || [ -L "$DEPLOY_TARGET" ]; then
  rename_bundle "$DEPLOY_TARGET" "$PREVIOUS_APP"
fi
rename_bundle "$STAGED_APP" "$DEPLOY_TARGET"
DEPLOYMENT_COMPLETE=1
