#!/bin/bash
# Everything a pull request must pass, in order of speed:
#   1. source size rule (400 lines per file)
#   2. InterviewCheckKit package tests (swift test, seconds, no app)
#   3. app build and app tests (xcodebuild via scripts/test.sh)
#   4. server type check and tests (when Node 22+ is available)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== Source size ==="
python3 scripts/check-source-size.py

echo "=== InterviewCheckKit (swift test) ==="
(cd Packages/InterviewCheckKit && swift test 2>&1 | tail -3)

echo "=== App tests ==="
./scripts/test.sh

echo "=== Server ==="
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -ge 22 ]; then
  (cd server && npm ci --ignore-scripts --no-audit --no-fund >/dev/null && npm run typecheck && npm test)
else
  echo "Skipped: the server needs Node 22+ (found ${NODE_MAJOR})."
fi

echo "CI passed."
