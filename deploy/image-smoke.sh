#!/usr/bin/env bash
# CI for pull requests: the server image must start on data that main's image wrote, and on no data.
# The Linux test job runs on the CI machine's own Python and SQLite, so it cannot see problems that only
# exist inside deploy/Dockerfile. On Nov 19 2026, merged code needed an SQLite option the image's SQLite
# did not have; every deploy failed and rolled back until the base image was changed (#29).
# Usage: deploy/image-smoke.sh <main's image> <this branch's image>
set -euo pipefail
BASE=$1
NEW=$2
DATA=$(mktemp -d)
sudo chown 10001:10001 "$DATA"
WEB=http://127.0.0.1:3000

started() {  # container name: wait for Docker's health check (deploy/Dockerfile HEALTHCHECK)
  for _ in $(seq 1 60); do
    state=$(docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null || echo missing)
    [ "$state" = healthy ] && { echo "$1: healthy"; return 0; }
    [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || break
    sleep 4
  done
  echo "::error::$1 did not become healthy. Last log lines:"
  docker logs --tail 80 "$1" 2>&1 || true
  return 1
}

echo "== main's image on an empty data folder (local mode, so the API takes records without sign-in)"
docker run -d --name base --network host -v "$DATA:/data" "$BASE" >/dev/null
started base

api() { curl -fsS -X POST "$WEB$1" -H "Origin: $WEB" -H "X-InterviewCheck: 1" -H "Content-Type: application/json" -d "$2"; }
# Seeding must work: checking the upgrade of an empty database would prove nothing.
sid=$(api /api/sessions '{"candidate":"Upgrade fixture","role":"Engineer","policy":"No AI tools.","consent":true}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') ||
  { echo "::error::Could not add an interview through main's API."; docker logs --tail 80 base 2>&1 || true; exit 1; }
api "/api/sessions/$sid/answers" '{"question":"How do you keep a slow dependency from failing checkout?",
  "answer":"Wrap it in a circuit breaker with a short timeout so we fail fast.",
  "references":[{"label":"AI answer","text":"Wrap it in a circuit breaker with a short timeout so we fail fast."}]}' >/dev/null ||
  { echo "::error::Could not add an answer through main's API."; docker logs --tail 80 base 2>&1 || true; exit 1; }
echo "seeded interview $sid with one answer"
docker stop -t 20 base >/dev/null
docker rm base >/dev/null

echo "== this branch's image on the same data folder, configured like production"
cat > "$RUNNER_TEMP/app.env" <<EOF
INTERVIEWCHECK_PUBLIC_ORIGIN=https://ci.interviewcheck.test
INTERVIEWCHECK_ACCESS_MODE=embedded
INTERVIEWCHECK_OPERATOR_EMAIL=operator@interviewcheck.test
INTERVIEWCHECK_SIGNUP_SECRET=$(openssl rand -hex 24)
ADMIN_EMAILS=operator@interviewcheck.test
ADMIN_BOOTSTRAP_SECRET=$(openssl rand -hex 24)
INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1
EOF
docker run -d --name new --network host --env-file "$RUNNER_TEMP/app.env" -v "$DATA:/data" "$NEW" >/dev/null
started new

docker exec -i new python - <<'PY'
import sqlite3
for name in ("review.sqlite3", "access.sqlite3"):
    with sqlite3.connect("/data/" + name) as db:
        result = db.execute("PRAGMA integrity_check").fetchone()[0]
        assert result == "ok", (name, result)
        print(name, "integrity ok")
with sqlite3.connect("/data/review.sqlite3") as db:
    sessions = db.execute("SELECT count(*) FROM sessions").fetchone()[0]
    answers = db.execute("SELECT count(*) FROM answers").fetchone()[0]
assert (sessions, answers) == (1, 1), f"main's interview did not survive the upgrade: {sessions} sessions, {answers} answers"
print("main's interview and answer survived the upgrade")
PY
docker stop -t 20 new >/dev/null

# The health check is /api/readyz, which must also pass on a first production start with no data yet.
echo "== this branch's image on an empty data folder, configured like production"
FRESH=$(mktemp -d)
sudo chown 10001:10001 "$FRESH"
docker run -d --name fresh --network host --env-file "$RUNNER_TEMP/app.env" -v "$FRESH:/data" "$NEW" >/dev/null
started fresh
docker stop -t 20 fresh >/dev/null
echo "Server image starts, upgrades main's data, and starts on an empty data folder."
