#!/bin/bash

set -euo pipefail

ENTITLEMENTS_FILE="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/InterviewCheck/InterviewCheck.entitlements"

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "ERROR: Entitlements file not found at: $ENTITLEMENTS_FILE" >&2
  exit 1
fi

if ! /usr/bin/plutil -p "$ENTITLEMENTS_FILE" | /usr/bin/grep -q "com.apple.security.device.audio-input"; then
  echo "ERROR: Missing com.apple.security.device.audio-input in InterviewCheck.entitlements" >&2
  echo "Hint: run ./scripts/sync-entitlements.sh after xcodegen generate" >&2
  exit 1
fi

echo "Entitlements verified successfully"
