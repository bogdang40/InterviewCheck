#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_FILE="$ROOT_DIR/InterviewCheck/InterviewCheck.entitlements.template"
DST_FILE="$ROOT_DIR/InterviewCheck/InterviewCheck.entitlements"

if [[ ! -f "$SRC_FILE" ]]; then
  echo "ERROR: Entitlements template missing at: $SRC_FILE" >&2
  exit 1
fi

if [[ -f "$DST_FILE" ]]; then
  chmod u+w "$DST_FILE" 2>/dev/null || true
fi

if [[ ! -f "$DST_FILE" ]]; then
  cp "$SRC_FILE" "$DST_FILE"
  chmod 444 "$DST_FILE"
  exit 0
fi

if ! /usr/bin/plutil -p "$DST_FILE" | /usr/bin/grep -q "com.apple.security.device.audio-input"; then
  cp "$SRC_FILE" "$DST_FILE"
fi

chmod 444 "$DST_FILE"
