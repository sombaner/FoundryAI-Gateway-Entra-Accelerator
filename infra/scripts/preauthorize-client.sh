#!/usr/bin/env bash
# Pre-authorize a client app for the AI-Gateway-API Inference.Invoke scope.
#
# Without pre-authorization, requesting a token for a custom API scope fails with
# AADSTS650057 "Invalid resource". This is required to mint validation tokens with
# the Azure CLI first-party app instead of a browser flow.
#
#   ./preauthorize-client.sh <client-app-id>
#
# Pre-authorization only removes the consent prompt; APIM still enforces which
# client app IDs it accepts via the client-application-ids policy element.
set -euo pipefail

CLIENT_TO_ADD="${1:?usage: preauthorize-client.sh <client-app-id>}"
ENV_FILE="$(cd -- "$(dirname -- "$0")" && pwd)/../azure.env"
set -a; . "$ENV_FILE"; set +a

GW="$GATEWAY_API_CLIENT_ID"
OBJ_ID=$(az ad app show --id "$GW" --query id -o tsv)
SCOPE_ID=$(az ad app show --id "$GW" --query "api.oauth2PermissionScopes[?value=='Inference.Invoke'] | [0].id" -o tsv)

echo "gateway app object id: $OBJ_ID"
echo "Inference.Invoke scope id: $SCOPE_ID"

EXISTING=$(az ad app show --id "$GW" --query "api.preAuthorizedApplications" -o json)
if echo "$EXISTING" | grep -q "$CLIENT_TO_ADD"; then
  echo "already pre-authorized: $CLIENT_TO_ADD"
  exit 0
fi

UPDATED=$(python3 - "$EXISTING" "$CLIENT_TO_ADD" "$SCOPE_ID" <<'PY'
import json, sys
existing = json.loads(sys.argv[1]) or []
existing.append({"appId": sys.argv[2], "delegatedPermissionIds": [sys.argv[3]]})
print(json.dumps({"api": {"preAuthorizedApplications": existing}}))
PY
)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "$UPDATED"

echo "pre-authorized: $CLIENT_TO_ADD"
az ad app show --id "$GW" --query "api.preAuthorizedApplications[].appId" -o json
