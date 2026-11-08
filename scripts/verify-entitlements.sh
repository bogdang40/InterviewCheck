#!/bin/bash

set -euo pipefail

ENTITLEMENTS_FILE="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/memanager/memanager.entitlements"

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "ERROR: Entitlements file not found at: $ENTITLEMENTS_FILE" >&2
  exit 1
fi

if ! /usr/bin/plutil -p "$ENTITLEMENTS_FILE" | /usr/bin/grep -q "com.apple.security.device.audio-input"; then
  echo "ERROR: Missing com.apple.security.device.audio-input in memanager.entitlements" >&2
  echo "Hint: run ./scripts/sync-entitlements.sh after xcodegen generate" >&2
  exit 1
fi

# Check for library validation entitlement (required for Eagle dylib)
if ! /usr/bin/plutil -p "$ENTITLEMENTS_FILE" | /usr/bin/grep -q "com.apple.security.cs.disable-library-validation"; then
  echo "ERROR: Missing com.apple.security.cs.disable-library-validation in memanager.entitlements" >&2
  echo "Hint: This is required for loading the Picovoice Eagle dylib" >&2
  exit 1
fi

echo "Entitlements verified successfully"
