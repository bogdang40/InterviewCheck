#!/usr/bin/env bash
# CI for pull requests: deploy/Caddyfile in front of this branch's image, run by the Caddy image that
# deploy/compose.yml pins. Plain HTTP on a local port stands in for the public site; the app is
# configured with the matching public origin, as production is behind Caddy.
# Usage: deploy/edge-smoke.sh <this branch's image>   (run from the repository root, after image-smoke.sh)
set -euo pipefail
NEW=$1
HOST=ci.interviewcheck.test:8080
SITE=http://$HOST
CADDY=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(caddy:[^[:space:]]*\).*$/\1/p' deploy/compose.yml)
[ "$(wc -w <<<"$CADDY")" = 1 ] || { echo "::error::Could not read one Caddy image from deploy/compose.yml: '$CADDY'"; exit 1; }
CADDYFILE="$PWD/deploy/Caddyfile:/etc/caddy/Caddyfile:ro"
cleanup() { docker rm -f edge-caddy edge-app >/dev/null 2>&1 || true; [ -z "${UPSTREAM:-}" ] || kill "$UPSTREAM" 2>/dev/null || true; }
trap cleanup EXIT
# The edge check below uses its own resolver, so give the site name an address on this machine.
grep -q " ${HOST%:*}\$" /etc/hosts || echo "127.0.0.1 ${HOST%:*}" | sudo tee -a /etc/hosts >/dev/null

fail() { echo "::error::$*"; exit 1; }
headers() { curl -sS -o /dev/null -D - --max-time 10 "$SITE$1" | tr -d '\r' | tr 'A-Z' 'a-z'; }
has() { grep -q "^$1" <<<"$2" || fail "$3 (headers: $(tr '\n' ' ' <<<"$2"))"; }
lacks() { ! grep -q "^$1" <<<"$2" || fail "$3 (headers: $(tr '\n' ' ' <<<"$2"))"; }

echo "== caddy validate ($CADDY)"
docker run --rm -e SITE_ADDRESS="$SITE" -v "$CADDYFILE" "$CADDY" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

docker run -d --name edge-caddy --network host -e SITE_ADDRESS="$SITE" -v "$CADDYFILE" "$CADDY" >/dev/null
for _ in $(seq 1 30); do curl -s -o /dev/null "$SITE/" && break; sleep 1; done

echo "== an upstream that labels nothing gets Caddy's defaults"
# Every app response carries its own headers, so a bare Python file server stands in on the app's port.
plain=$(mktemp -d)
echo ok > "$plain/index.html"
python3 -m http.server 3000 --bind 127.0.0.1 --directory "$plain" >/dev/null 2>&1 &
UPSTREAM=$!
for _ in $(seq 1 20); do curl -fs -o /dev/null http://127.0.0.1:3000/ && break; sleep 0.5; done
h=$(headers /)
has "http/1.1 200" "$h" "the plain upstream did not answer through Caddy"
has "content-security-policy: frame-ancestors 'none'" "$h" "no default Content-Security-Policy"
has "referrer-policy: no-referrer" "$h" "no default Referrer-Policy"
has "x-frame-options: deny" "$h" "no default X-Frame-Options"
has "x-content-type-options: nosniff" "$h" "no default X-Content-Type-Options"
has "strict-transport-security: max-age=" "$h" "no Strict-Transport-Security"
lacks "server:" "$h" "the upstream's Server header got through"
kill "$UPSTREAM"; wait "$UPSTREAM" 2>/dev/null || true; UPSTREAM=""
echo "defaults applied"

echo "== this branch's image behind Caddy, configured like production"
data=$(mktemp -d)
sudo chown 10001:10001 "$data"
cat > "$RUNNER_TEMP/edge.env" <<EOF
INTERVIEWCHECK_PUBLIC_ORIGIN=https://$HOST
INTERVIEWCHECK_ACCESS_MODE=embedded
INTERVIEWCHECK_OPERATOR_EMAIL=operator@interviewcheck.test
INTERVIEWCHECK_SIGNUP_SECRET=$(openssl rand -hex 24)
ADMIN_EMAILS=operator@interviewcheck.test
ADMIN_BOOTSTRAP_SECRET=$(openssl rand -hex 24)
INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1
EOF
docker run -d --name edge-app --network host --env-file "$RUNNER_TEMP/edge.env" -v "$data:/data" "$NEW" >/dev/null
for _ in $(seq 1 60); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' edge-app)" = healthy ] && break
  [ "$(docker inspect --format '{{.State.Running}}' edge-app)" = true ] || break
  sleep 4
done
[ "$(docker inspect --format '{{.State.Health.Status}}' edge-app)" = healthy ] ||
  { docker logs --tail 80 edge-app 2>&1 || true; fail "edge-app did not become healthy"; }

h=$(headers /)
has "http/1.1 200" "$h" "the home page did not answer through Caddy"
has "content-security-policy: .*script-src" "$h" "the home page lost the app's Content-Security-Policy"
has "referrer-policy: no-referrer" "$h" "the home page lost the app's Referrer-Policy"
has "strict-transport-security: max-age=" "$h" "no Strict-Transport-Security"
lacks "server:" "$h" "a Server header got through"
has "http/1.1 200" "$(headers /api/readyz)" "/api/readyz did not answer through Caddy"
echo "the app's own headers reach the browser"

echo "== scripts/verify_edge_security.py --edge, with the image's own Python and httpx"
# The container shares this machine's network and its /etc/hosts entry; run.py keeps the app's packages in portable/.venv.
docker exec -i edge-app /app/portable/.venv/bin/python - --base-url "$SITE" --edge < scripts/verify_edge_security.py
echo "Caddyfile validated; Caddy defaults, app headers and the edge checks hold through Caddy."
