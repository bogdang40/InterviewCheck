#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUTPUT="$ROOT_DIR/build/DerivedData/Build/Products/Debug/memanager.app"
DEPLOY_TARGET="$HOME/.interviewcheck/InterviewCheck.app"
DEVELOPMENT_TEAM_ID="${MEMANAGER_DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY_VALUE="${MEMANAGER_CODE_SIGN_IDENTITY:-Apple Development}"
USE_ADHOC_SIGNING=0

if [ -z "$DEVELOPMENT_TEAM_ID" ]; then
  USE_ADHOC_SIGNING=1
  echo "WARNING: MEMANAGER_DEVELOPMENT_TEAM is not set. Falling back to ad-hoc signing."
fi

cd "$ROOT_DIR"
python3 "$ROOT_DIR/scripts/check-source-size.py"

echo "=== Generating Xcode project ==="
xcodegen generate

echo "=== Syncing entitlements ==="
./scripts/sync-entitlements.sh

echo "=== Verifying entitlements ==="
./scripts/verify-entitlements.sh

echo "=== Building Debug ==="
if [ "$USE_ADHOC_SIGNING" -eq 1 ]; then
  xcodebuild -project memanager.xcodeproj -scheme memanager -configuration Debug \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  xcodebuild -project memanager.xcodeproj -scheme memanager -configuration Debug \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_VALUE" \
    build
fi

/bin/bash "$ROOT_DIR/scripts/deploy-app.sh" "$BUILD_OUTPUT" "$DEPLOY_TARGET" \
  "$USE_ADHOC_SIGNING" "$ROOT_DIR/memanager/memanager.entitlements" Debug

# Clear old debug log
rm -f "$HOME/Desktop/deepgram_debug.log"

echo ""
echo "=========================================="
echo "DEBUG BUILD COMPLETE"
echo "=========================================="
echo "Deployed to: $DEPLOY_TARGET"
echo "Log file: ~/Desktop/deepgram_debug.log"
echo ""
echo "To run: open '$DEPLOY_TARGET'"
echo "After testing, check: cat ~/Desktop/deepgram_debug.log"
echo "=========================================="
