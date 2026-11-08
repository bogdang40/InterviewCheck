#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
RESULT_BUNDLE_DIR="$BUILD_DIR/xcresult-export"
RESULT_BUNDLE_PATH="$RESULT_BUNDLE_DIR/memanager-tests.xcresult"
DEVELOPMENT_TEAM_ID="${MEMANAGER_DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY_VALUE="${MEMANAGER_CODE_SIGN_IDENTITY:-Apple Development}"
USE_ADHOC_SIGNING=0

# Xcode forwards TEST_RUNNER_ variables to the test host before app startup.
# Explicitly select isolated storage even before XCTest classes are loaded.
export TEST_RUNNER_MEMANAGER_TEST_PROCESS=1

warn_duplicate_derived_data() {
    shopt -s nullglob
    local derived_data_paths=( "$BUILD_DIR"/DerivedData* )
    shopt -u nullglob

    if [ "${#derived_data_paths[@]}" -gt 1 ]; then
        echo "WARNING: Found ${#derived_data_paths[@]} DerivedData directories under $BUILD_DIR"
        printf '  %s\n' "${derived_data_paths[@]##*/}"
        echo "Run ./scripts/clean.sh to remove duplicate caches."
        echo ""
    fi
}

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/test.sh [xcodebuild test options]

Examples:
  ./scripts/test.sh
  ./scripts/test.sh -only-testing:memanagerTests/SeparateStreamAudioRouterTests

This wrapper always reuses build/DerivedData and overwrites
build/xcresult-export/memanager-tests.xcresult.
EOF
    exit 0
fi

if [ -z "$DEVELOPMENT_TEAM_ID" ]; then
    USE_ADHOC_SIGNING=1
    echo "WARNING: MEMANAGER_DEVELOPMENT_TEAM is not set. Falling back to unsigned local test configuration."
fi

mkdir -p "$BUILD_DIR" "$RESULT_BUNDLE_DIR"
rm -rf "$RESULT_BUNDLE_PATH"

python3 "$ROOT_DIR/scripts/check-source-size.py"
STORAGE_SNAPSHOT="$RESULT_BUNDLE_DIR/live-storage-before.json"
python3 "$ROOT_DIR/scripts/test-storage-guard.py" snapshot "$STORAGE_SNAPSHOT"
finish() {
    local status=$?
    trap - EXIT
    if ! python3 "$ROOT_DIR/scripts/test-storage-guard.py" verify "$STORAGE_SNAPSHOT"; then
        status=1
    fi
    exit "$status"
}
trap finish EXIT

warn_duplicate_derived_data

cd "$ROOT_DIR"

echo "=== Generating Xcode project ==="
xcodegen generate

echo "=== Syncing entitlements ==="
./scripts/sync-entitlements.sh

echo "=== Verifying entitlements ==="
./scripts/verify-entitlements.sh

echo "=== Running tests ==="
if [ "$USE_ADHOC_SIGNING" -eq 1 ]; then
    xcodebuild -project memanager.xcodeproj -scheme memanager \
        -destination "platform=macOS" \
        -parallel-testing-enabled NO \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -resultBundlePath "$RESULT_BUNDLE_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        test \
        "$@"
else
    xcodebuild -project memanager.xcodeproj -scheme memanager \
        -destination "platform=macOS" \
        -parallel-testing-enabled NO \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -resultBundlePath "$RESULT_BUNDLE_PATH" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_VALUE" \
        test \
        "$@"
fi

xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH" \
    > "$RESULT_BUNDLE_DIR/test-summary.json"
python3 - "$RESULT_BUNDLE_DIR/test-summary.json" <<'PYTHON'
import json
import sys
with open(sys.argv[1]) as stream:
    summary = json.load(stream)
executed = summary["totalTestCount"] - summary["skippedTests"]
if executed <= 0 or summary["failedTests"] > 0:
    raise SystemExit(f"Invalid run: {executed} executed, {summary['failedTests']} failed")
print(f"Verified {executed} executed tests, {summary['skippedTests']} skipped.")
PYTHON

echo ""
echo "=========================================="
echo "TEST RUN COMPLETE"
echo "=========================================="
echo "Result bundle: $RESULT_BUNDLE_PATH"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "=========================================="
