#!/usr/bin/env bash
# Claude Governance MVP — Entra ID fallback deployment script
#
# Use this ONLY if your environment cannot use the Bicep Microsoft Graph
# extension (infra/entra/entra.bicep), e.g. because Bicep extensibility is an
# experimental feature you don't want enabled, or your Bicep CLI is too old.
#
# Performs the same operations as entra.bicep, idempotently:
#   - Create/reuse "AI-Gateway-API" app registration (resource/audience app)
#     with an Inference.Invoke delegated scope and an AI.Gateway.User app role
#   - Create/reuse its service principal
#   - Create/reuse "Claude-Cowork-Client" public client app (PKCE, no secret)
#     with required resource access to the Inference.Invoke scope
#   - Create/reuse its service principal
#   - Create/reuse the "sg-claude-desktop-pilot" security group
#   - Assign the pilot group the AI.Gateway.User app role
#
# Requires: az CLI logged in (az login) with sufficient Entra permissions
# (Application.ReadWrite.All / Group.ReadWrite.All, or Global Administrator /
# Application Administrator + Groups Administrator roles).
#
# This script is READ-ONLY / SAFE TO INSPECT. It performs NO Azure resource
# deployment (APIM, Foundry, etc.) — only Entra ID objects. It does not
# execute automatically; run it explicitly when you are ready.
#
# Usage:
#   chmod +x deploy-entra.sh
#   ./deploy-entra.sh
#
set -euo pipefail

GATEWAY_API_DISPLAY_NAME="${GATEWAY_API_DISPLAY_NAME:-AI-Gateway-API}"
COWORK_CLIENT_DISPLAY_NAME="${COWORK_CLIENT_DISPLAY_NAME:-Claude-Cowork-Client}"
PILOT_GROUP_DISPLAY_NAME="${PILOT_GROUP_DISPLAY_NAME:-sg-claude-desktop-pilot}"
PILOT_GROUP_MAIL_NICKNAME="${PILOT_GROUP_MAIL_NICKNAME:-sg-claude-desktop-pilot}"
REDIRECT_URI="${REDIRECT_URI:-http://127.0.0.1/callback}"

# Fixed, stable identifiers — must match infra/entra/entra.bicep exactly so
# the Bicep and script paths are interchangeable / idempotent with each other.
INFERENCE_INVOKE_SCOPE_ID="a1b2c3d4-1111-4a2b-8c3d-000000000001"
GATEWAY_USER_APPROLE_ID="a1b2c3d4-2222-4a2b-8c3d-000000000002"

echo "== Claude Governance MVP: Entra ID fallback setup =="
echo "Signed in as:"
az account show --query "{user:user.name, tenant:tenantId}" -o table

# ---------------------------------------------------------------------------
# 1. AI-Gateway-API (resource/audience app)
# ---------------------------------------------------------------------------
GATEWAY_APP_ID=$(az ad app list --display-name "$GATEWAY_API_DISPLAY_NAME" --query "[0].appId" -o tsv)

if [[ -z "$GATEWAY_APP_ID" ]]; then
  echo "Creating app registration: $GATEWAY_API_DISPLAY_NAME"
  GATEWAY_APP_ID=$(az ad app create \
    --display-name "$GATEWAY_API_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)

  # Identifier URI — REQUIRED for "api://<appId>/<scope>" to resolve at token
  # request time. Without this, sign-in fails with AADSTS500011 "resource
  # principal not found" even though the app registration exists.
  az ad app update --id "$GATEWAY_APP_ID" --identifier-uris "api://$GATEWAY_APP_ID"

  # Delegated scope: Inference.Invoke
  az ad app update --id "$GATEWAY_APP_ID" --set api="{
    \"requestedAccessTokenVersion\": 2,
    \"oauth2PermissionScopes\": [{
      \"id\": \"$INFERENCE_INVOKE_SCOPE_ID\",
      \"adminConsentDisplayName\": \"Invoke governed inference\",
      \"adminConsentDescription\": \"Allows the calling application to invoke the governed Claude inference gateway on behalf of the signed-in user.\",
      \"userConsentDisplayName\": \"Invoke governed inference\",
      \"userConsentDescription\": \"Allows the app to send prompts to the governed Claude inference gateway on your behalf.\",
      \"value\": \"Inference.Invoke\",
      \"type\": \"User\",
      \"isEnabled\": true
    }]
  }"

  # App role: AI.Gateway.User
  az ad app update --id "$GATEWAY_APP_ID" --app-roles "[{
    \"id\": \"$GATEWAY_USER_APPROLE_ID\",
    \"displayName\": \"AI Gateway User\",
    \"description\": \"Members of the assigned security group are entitled to use the Claude Desktop pilot inference gateway.\",
    \"value\": \"AI.Gateway.User\",
    \"allowedMemberTypes\": [\"User\", \"Group\"],
    \"isEnabled\": true
  }]"
else
  echo "Reusing existing app registration: $GATEWAY_API_DISPLAY_NAME ($GATEWAY_APP_ID)"
fi

# Idempotent safety net: ensure identifierUris is set even if the app already
# existed from a prior run of this script (or was created before this fix).
EXISTING_IDENTIFIER_URIS=$(az ad app show --id "$GATEWAY_APP_ID" --query "identifierUris" -o tsv)
if [[ -z "$EXISTING_IDENTIFIER_URIS" ]]; then
  echo "Setting missing identifierUris on $GATEWAY_API_DISPLAY_NAME"
  az ad app update --id "$GATEWAY_APP_ID" --identifier-uris "api://$GATEWAY_APP_ID"
fi

GATEWAY_SP_ID=$(az ad sp list --filter "appId eq '$GATEWAY_APP_ID'" --query "[0].id" -o tsv)
if [[ -z "$GATEWAY_SP_ID" ]]; then
  echo "Creating service principal for $GATEWAY_API_DISPLAY_NAME"
  GATEWAY_SP_ID=$(az ad sp create --id "$GATEWAY_APP_ID" --query id -o tsv)
else
  echo "Reusing existing service principal for $GATEWAY_API_DISPLAY_NAME ($GATEWAY_SP_ID)"
fi

# ---------------------------------------------------------------------------
# 2. Claude-Cowork-Client (public client, PKCE, no secret)
# ---------------------------------------------------------------------------
COWORK_APP_ID=$(az ad app list --display-name "$COWORK_CLIENT_DISPLAY_NAME" --query "[0].appId" -o tsv)

if [[ -z "$COWORK_APP_ID" ]]; then
  echo "Creating app registration: $COWORK_CLIENT_DISPLAY_NAME"
  COWORK_APP_ID=$(az ad app create \
    --display-name "$COWORK_CLIENT_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --is-fallback-public-client true \
    --public-client-redirect-uris "$REDIRECT_URI" \
    --required-resource-accesses "[{
      \"resourceAppId\": \"$GATEWAY_APP_ID\",
      \"resourceAccess\": [{
        \"id\": \"$INFERENCE_INVOKE_SCOPE_ID\",
        \"type\": \"Scope\"
      }]
    }]" \
    --query appId -o tsv)
else
  echo "Reusing existing app registration: $COWORK_CLIENT_DISPLAY_NAME ($COWORK_APP_ID)"
fi

COWORK_SP_ID=$(az ad sp list --filter "appId eq '$COWORK_APP_ID'" --query "[0].id" -o tsv)
if [[ -z "$COWORK_SP_ID" ]]; then
  echo "Creating service principal for $COWORK_CLIENT_DISPLAY_NAME"
  COWORK_SP_ID=$(az ad sp create --id "$COWORK_APP_ID" --query id -o tsv)
else
  echo "Reusing existing service principal for $COWORK_CLIENT_DISPLAY_NAME ($COWORK_SP_ID)"
fi

# ---------------------------------------------------------------------------
# 3. Pilot security group
# ---------------------------------------------------------------------------
PILOT_GROUP_ID=$(az ad group list --display-name "$PILOT_GROUP_DISPLAY_NAME" --query "[0].id" -o tsv)

if [[ -z "$PILOT_GROUP_ID" ]]; then
  echo "Creating security group: $PILOT_GROUP_DISPLAY_NAME"
  PILOT_GROUP_ID=$(az ad group create \
    --display-name "$PILOT_GROUP_DISPLAY_NAME" \
    --mail-nickname "$PILOT_GROUP_MAIL_NICKNAME" \
    --query id -o tsv)
else
  echo "Reusing existing security group: $PILOT_GROUP_DISPLAY_NAME ($PILOT_GROUP_ID)"
fi

# ---------------------------------------------------------------------------
# 4. Assign the pilot group the AI.Gateway.User app role
# ---------------------------------------------------------------------------
EXISTING_ASSIGNMENT=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$GATEWAY_SP_ID/appRoleAssignedTo" \
  --query "value[?principalId=='$PILOT_GROUP_ID'] | [0].id" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_ASSIGNMENT" ]]; then
  echo "Assigning AI.Gateway.User app role to $PILOT_GROUP_DISPLAY_NAME"
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$GATEWAY_SP_ID/appRoleAssignedTo" \
    --body "{
      \"principalId\": \"$PILOT_GROUP_ID\",
      \"resourceId\": \"$GATEWAY_SP_ID\",
      \"appRoleId\": \"$GATEWAY_USER_APPROLE_ID\"
    }" >/dev/null
else
  echo "App role assignment already exists ($EXISTING_ASSIGNMENT)"
fi

# ---------------------------------------------------------------------------
# Summary — feed these into infra/main.bicepparam and Claude Desktop config
# ---------------------------------------------------------------------------
echo ""
echo "== Done. Record these values =="
echo "gatewayApiClientId (AI-Gateway-API appId):        $GATEWAY_APP_ID"
echo "coworkClientId (Claude-Cowork-Client appId):      $COWORK_APP_ID"
echo "pilotGroupId (sg-claude-desktop-pilot object id): $PILOT_GROUP_ID"
echo "gatewayApiServicePrincipalId:                     $GATEWAY_SP_ID"
echo ""
echo "Add pilot users afterward with:"
echo "  az ad group member add --group $PILOT_GROUP_ID --member-id <user-object-id>"
