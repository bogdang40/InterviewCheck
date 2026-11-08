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

echo "Sending request..."
curl -sS -D /tmp/azure_api_test_headers.txt \
  -H "Content-Type: application/json" \
  -H "api-key: ${api_key}" \
  -d "${payload}" \
  "${url}" \
  -o /tmp/azure_api_test_body.txt

status=$(awk 'NR==1 {print $2}' /tmp/azure_api_test_headers.txt)
echo "HTTP status: ${status}"
echo "Response body:"
cat /tmp/azure_api_test_body.txt
