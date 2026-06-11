#!/usr/bin/env bash
# Register your relay URL with replicant.space and capture the one-time secret.
#
# Usage:
#   REPLICANT_API_KEY=rs_xxx ./scripts/register-webhook.sh https://your-relay.vercel.app/api/webhook
#
# Notes:
#   - The webhook_secret in the response is shown EXACTLY ONCE. This script
#     prints the vercel CLI command to store it immediately.
#   - Webhook changes are limited to 12/hour, so don't iterate on this.
#     Deploy the relay FIRST — the game POSTs a verification challenge to the
#     URL during registration, and the relay must be live to echo it back.

set -euo pipefail

URL="${1:?usage: register-webhook.sh <https-url-of-deployed-relay>}"
: "${REPLICANT_API_KEY:?set REPLICANT_API_KEY to your game API token}"

RESPONSE=$(curl -sS -X POST https://api.replicant.space/v1/accounts/webhook \
  -H "Authorization: Bearer ${REPLICANT_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"url\": \"${URL}\"}")

echo "${RESPONSE}"
echo
SECRET=$(echo "${RESPONSE}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("webhook_secret",""))')

if [ -n "${SECRET}" ]; then
  echo "Store the secret NOW (it will never be shown again):"
  echo
  echo "  printf '%s' '${SECRET}' | vercel env add REPLICANT_WEBHOOK_SECRET production"
  echo
  echo "Then redeploy: vercel --prod"
else
  echo "No webhook_secret in response — registration may have failed. See response above."
fi
