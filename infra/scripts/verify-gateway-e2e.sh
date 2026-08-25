#!/usr/bin/env bash
# AI Gateway — end-to-end verification.
#
# Exercises identity, admission, safety, quota, telemetry, and both wire formats
# through APIM. Requires a real Entra access token minted by the Claude-Cowork-Client
# public client (Azure CLI cannot mint tokens for a custom API audience — see the
# apim-foundry-ai-gateway-best-practices skill, section 2).
#
#   python3 infra/scripts/get-gateway-token.py > /tmp/gw.token
#   GATEWAY_TOKEN=$(cat /tmp/gw.token) ./infra/scripts/verify-gateway-e2e.sh
#
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/../azure.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi

: "${GATEWAY_URL:?Set GATEWAY_URL in infra/azure.env}"
: "${GATEWAY_TOKEN:?Set GATEWAY_TOKEN (see header for how to mint one)}"

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ # name expected actual
  if [ "$3" = "$2" ]; then ok "$1 -> $3"; else bad "$1 (expected $2, got $3)"; fi
}

anthropic_call() { # model outfile -> http code
  curl -sS -o "$2" -w '%{http_code}' -X POST "$GATEWAY_URL/v1/messages" \
    -H "Authorization: Bearer $GATEWAY_TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"$1\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: ok\"}]}"
}

openai_call() { # model outfile -> http code
  curl -sS -o "$2" -w '%{http_code}' -X POST "$GATEWAY_URL/openai/v1/chat/completions" \
    -H "Authorization: Bearer $GATEWAY_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: ok\"}]}"
}

echo "=== gateway: $GATEWAY_URL ==="

echo
echo "--- 1. identity ---"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/v1/messages" \
  -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
check "no token rejected" 401 "$code"

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/v1/messages" \
  -H 'Authorization: Bearer not.a.real.token' -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
check "garbage token rejected" 401 "$code"

code=$(curl -sS -o /tmp/gw-models.json -w '%{http_code}' "$GATEWAY_URL/v1/models" \
  -H "Authorization: Bearer $GATEWAY_TOKEN")
check "discovery with valid token" 200 "$code"
[ -s /tmp/gw-models.json ] && echo "      $(head -c 300 /tmp/gw-models.json)"

echo
echo "--- 2. admission (model allowlist) ---"
code=$(anthropic_call "claude-haiku-3" /tmp/gw-deny.json)
check "unapproved claude model rejected" 403 "$code"

code=$(openai_call "gpt-4o" /tmp/gw-deny2.json)
check "unapproved openai model rejected" 403 "$code"

echo
echo "--- 3. inference through managed identity ---"
for m in claude-opus-5 claude-sonnet-5; do
  code=$(anthropic_call "$m" "/tmp/gw-$m.json")
  check "$m" 200 "$code"
  [ "$code" != "200" ] && head -c 400 "/tmp/gw-$m.json" && echo
done

code=$(openai_call "gpt-5.4" /tmp/gw-gpt.json)
check "gpt-5.4" 200 "$code"
[ "$code" != "200" ] && head -c 400 /tmp/gw-gpt.json && echo

echo
echo "--- 4. quota headers present ---"
HDRS=$(curl -sS -D - -o /dev/null -X POST "$GATEWAY_URL/v1/messages" \
  -H "Authorization: Bearer $GATEWAY_TOKEN" -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
echo "$HDRS" | grep -qi 'x-user-tpm-remaining' && ok "per-user TPM header emitted" || bad "per-user TPM header missing"
echo "$HDRS" | grep -qi 'x-user-quota-remaining' && ok "per-user quota header emitted" || bad "per-user quota header missing"

echo
echo "--- 5. no key material returned to the client ---"
if echo "$HDRS" | grep -qiE '^(x-api-key|api-key|ocp-apim-subscription-key):'; then
  bad "credential header echoed to client"
else
  ok "no credential headers in the client exchange"
fi

echo
echo "--- 6. streaming (SSE must not buffer) ---"
STREAM=$(curl -sSN --max-time 60 -X POST "$GATEWAY_URL/v1/messages" \
  -H "Authorization: Bearer $GATEWAY_TOKEN" -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"Count 1 to 10."}]}' \
  | head -5)
echo "$STREAM" | grep -q 'event:' && ok "SSE events streamed" || bad "no SSE events returned"

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
