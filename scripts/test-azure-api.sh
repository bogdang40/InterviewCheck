#!/usr/bin/env bash
set -euo pipefail

endpoint="${AZURE_ENDPOINT:-}"
deployment="${AZURE_DEPLOYMENT:-}"
api_version="${AZURE_API_VERSION:-2024-02-01}"
api_key="${AZURE_API_KEY:-}"

if [[ -z "$endpoint" || -z "$deployment" || -z "$api_key" ]]; then
  echo "Missing required env vars."
  echo "Set AZURE_ENDPOINT, AZURE_DEPLOYMENT, AZURE_API_KEY and optional AZURE_API_VERSION."
  exit 1
fi

endpoint="${endpoint%/}"
url="${endpoint}/openai/deployments/${deployment}/chat/completions?api-version=${api_version}"

cat <<EOF
Azure request:
  endpoint: ${endpoint}
  deployment: ${deployment}
  api_version: ${api_version}
  url: ${url}
EOF

payload='{
  "messages": [
    {"role": "system", "content": "You are a short-response tester."},
    {"role": "user", "content": "Say OK."}
  ],
  "max_tokens": 16
}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Sending request..."
status=$(curl -sS -o "$work/body.txt" -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -H "api-key: ${api_key}" \
  -d "${payload}" \
  "${url}") || status=000
echo "HTTP status: ${status}"
echo "Response body:"
cat "$work/body.txt" 2>/dev/null || true
echo
case "$status" in
  2??) ;;
  *) echo "Azure request failed with HTTP status ${status}." >&2; exit 1 ;;
esac
