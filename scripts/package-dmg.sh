#!/bin/bash
# Packages the installed Release build as a drag-to-Applications disk image:
#   ./scripts/build-release.sh && ./scripts/package-dmg.sh
# Output: build/InterviewCheck-<version>.dmg
#
# Distribution outside this Mac also needs a Developer ID signature with the
# hardened runtime and Apple notarization (xcrun notarytool), which require
# an Apple Developer account; see README.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/InterviewCheck.app}"
[ -d "$APP" ] || { echo "No app at $APP. Run ./scripts/build-release.sh first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/interviewcheck-dmg.XXXXXX")"
trap 'rm -rf "${STAGING:?}"' EXIT
OUT="$ROOT_DIR/build/InterviewCheck-$VERSION.dmg"

ditto "$APP" "$STAGING/InterviewCheck.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$ROOT_DIR/build"
rm -f "$OUT"
hdiutil create -volname "InterviewCheck $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
