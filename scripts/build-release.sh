#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUTPUT="$ROOT_DIR/build/DerivedData/Build/Products/Release/InterviewCheck.app"
DEPLOY_TARGET="$HOME/Applications/InterviewCheck.app"
DEVELOPMENT_TEAM_ID="${INTERVIEWCHECK_DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY_VALUE="${INTERVIEWCHECK_CODE_SIGN_IDENTITY:-Apple Development}"
USE_ADHOC_SIGNING=0
DEPLOY=1

if [ "$#" -gt 1 ]; then
  echo "Usage: ./scripts/build-release.sh [--build-only]" >&2
  exit 2
fi
case "${1:-}" in
  --build-only) DEPLOY=0 ;;
  --help)
    echo "Usage: ./scripts/build-release.sh [--build-only]"
    echo "Build Release; --build-only leaves the installed app unchanged."
    exit 0
    ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

if [ -z "$DEVELOPMENT_TEAM_ID" ]; then
  USE_ADHOC_SIGNING=1
  echo "WARNING: INTERVIEWCHECK_DEVELOPMENT_TEAM is not set. Falling back to ad-hoc signing."
fi

cd "$ROOT_DIR"
python3 "$ROOT_DIR/scripts/check-source-size.py"

echo "=== Generating Xcode project ==="
xcodegen generate

echo "=== Syncing entitlements ==="
./scripts/sync-entitlements.sh

echo "=== Verifying entitlements ==="
./scripts/verify-entitlements.sh

echo "=== Building Release ==="
if [ "$USE_ADHOC_SIGNING" -eq 1 ]; then
  xcodebuild -project InterviewCheck.xcodeproj -scheme InterviewCheck -configuration Release \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  xcodebuild -project InterviewCheck.xcodeproj -scheme InterviewCheck -configuration Release \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_VALUE" \
    build
fi

if [ "$DEPLOY" -eq 0 ]; then
  echo "Release build verified: $BUILD_OUTPUT"
  exit 0
fi

/bin/bash "$ROOT_DIR/scripts/deploy-app.sh" "$BUILD_OUTPUT" "$DEPLOY_TARGET" \
  "$USE_ADHOC_SIGNING" "$ROOT_DIR/InterviewCheck/InterviewCheck.entitlements" Release

echo ""
echo "=========================================="
echo "BUILD COMPLETE"
echo "=========================================="
echo "Deployed to: $DEPLOY_TARGET"
echo ""
echo "To run: open '$DEPLOY_TARGET'"
echo "=========================================="
