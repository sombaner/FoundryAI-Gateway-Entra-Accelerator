#!/usr/bin/env bash
# Post-registration Entra steps: admin consent, pilot group membership, config verification.
set -uo pipefail

GW="${GATEWAY_API_CLIENT_ID:?}"
CL="${COWORK_CLIENT_ID:?}"
GRP="${PILOT_GROUP_ID:?}"

echo "=== gateway app api config ==="
az ad app show --id "$GW" \
  --query "{tokenVer:api.requestedAccessTokenVersion, scopes:api.oauth2PermissionScopes[].value, idUris:identifierUris, roles:appRoles[].value}" -o json

echo "=== client redirect URIs ==="
az ad app show --id "$CL" --query "publicClient.redirectUris" -o json

echo "=== admin consent ==="
if az ad app permission admin-consent --id "$CL" 2>/tmp/consent.err; then
  echo "admin consent: OK"
else
  echo "admin consent: FAILED"
  tail -3 /tmp/consent.err
fi

echo "=== pilot group membership ==="
ME=$(az ad signed-in-user show --query id -o tsv)
echo "signed-in user object id: $ME"
az ad group member add --group "$GRP" --member-id "$ME" 2>/dev/null && echo "added" || echo "already a member (or add failed)"
echo -n "is member: "
az ad group member check --group "$GRP" --member-id "$ME" --query value -o tsv

echo "=== oauth2 grants on client SP ==="
CL_SP=$(az ad sp list --filter "appId eq '$CL'" --query "[0].id" -o tsv)
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$CL_SP/oauth2PermissionGrants" \
  --query "value[].{resource:resourceId,scope:scope,type:consentType}" -o json
