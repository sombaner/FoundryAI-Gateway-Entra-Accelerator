#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PROFILE="$REPO_ROOT/infra/claude-desktop/claude-gateway.mobileconfig"
MANAGED_SETTINGS="$REPO_ROOT/infra/claude-desktop/managed-settings.example.json"
ENV_FILE="$REPO_ROOT/infra/azure.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${GATEWAY_URL:?Set GATEWAY_URL in infra/azure.env (see infra/azure.env.example)}"
: "${AZURE_TENANT_ID:?Set AZURE_TENANT_ID in infra/azure.env (see infra/azure.env.example)}"
: "${COWORK_CLIENT_ID:?Set COWORK_CLIENT_ID in infra/azure.env (see infra/azure.env.example)}"
: "${GATEWAY_API_CLIENT_ID:?Set GATEWAY_API_CLIENT_ID in infra/azure.env (see infra/azure.env.example)}"
TENANT_ID="$AZURE_TENANT_ID"
CLIENT_ID="$COWORK_CLIENT_ID"
GATEWAY_API_ID="$GATEWAY_API_CLIENT_ID"
PROFILE_ID="com.anthropic.claudefordesktop.gateway"
PREFERENCE_DOMAIN="com.anthropic.claudefordesktop"
RUN_DIRECT_TESTS=false
PROFILE_INSTALLED=false

usage() {
  cat <<'EOF'
Usage: verify-claude-gateway.sh [--direct-tests]

Checks the local Claude managed profile and APIM ingress without exposing
credentials. --direct-tests starts the separate browser PKCE flow if needed and
tests both /v1/models and /v1/messages.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --direct-tests)
      RUN_DIRECT_TESTS=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for command in plutil profiles curl jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR required command is unavailable: %s\n' "$command" >&2
    exit 1
  fi
done

if ! plutil -lint "$PROFILE" >/dev/null; then
  printf 'ERROR source profile is not a valid plist: %s\n' "$PROFILE" >&2
  exit 1
fi
printf 'PASS source profile is valid\n'

profile_inference=$(plutil -convert json -o - "$PROFILE" | jq -cS '.PayloadContent[0].PayloadContent["com.anthropic.claudefordesktop"].Forced[0].mcx_preference_settings.inference') || {
  printf 'ERROR unable to read inference settings from source profile\n' >&2
  exit 1
}
managed_inference=$(jq -cS '.inference' "$MANAGED_SETTINGS") || {
  printf 'ERROR portable managed settings are not valid JSON: %s\n' "$MANAGED_SETTINGS" >&2
  exit 1
}
if [ "$profile_inference" != "$managed_inference" ]; then
  printf 'ERROR macOS profile and portable managed inference settings differ\n' >&2
  exit 1
fi
printf 'PASS managed inference artifacts are synchronized\n'

expected_issuer="https://login.microsoftonline.com/$TENANT_ID/v2.0"
expected_scope="api://$GATEWAY_API_ID/Inference.Invoke"
if ! printf '%s' "$managed_inference" | jq -e \
  --arg gateway_url "$GATEWAY_URL" \
  --arg client_id "$CLIENT_ID" \
  --arg issuer "$expected_issuer" \
  --arg scope "$expected_scope" \
  '.provider == "gateway" and
   .baseUrl == $gateway_url and
   .credential.kind == "interactive" and
   .credential.authFlow == "browser" and
   .credential.oidc.clientId == $client_id and
   .credential.oidc.issuer == $issuer and
   .credential.oidc.bearerTokenType == "access_token" and
   .credential.oidc.scopes == $scope and
   .credential.oidc.appendOfflineAccess == true' >/dev/null; then
  printf 'ERROR managed inference settings do not match the required Claude/Entra OIDC contract\n' >&2
  exit 1
fi
printf 'PASS managed inference settings match the Claude/Entra OIDC contract\n'

if profiles list -type configuration -user "$USER" 2>/dev/null | grep -q "$PROFILE_ID"; then
  printf 'PASS Claude gateway profile is installed\n'
  PROFILE_INSTALLED=true
else
  printf 'BLOCKED Claude gateway profile requires approval in System Settings > General > Device Management\n'
  printf '        Open: %s\n' "$PROFILE"
fi

if [ "$PROFILE_INSTALLED" = true ] && defaults read "$PREFERENCE_DOMAIN" inference >/dev/null 2>&1; then
  printf 'PASS Claude managed inference preference is visible\n'
elif [ "$PROFILE_INSTALLED" = true ]; then
  printf 'WARN profile is installed but the inference preference is not visible yet; quit and reopen Claude Desktop\n'
fi

status=$(curl -sS -o /dev/null -w '%{http_code}' "$GATEWAY_URL/v1/models") || {
  printf 'ERROR APIM gateway is unreachable: %s\n' "$GATEWAY_URL" >&2
  exit 1
}
if [ "$status" = "401" ]; then
  printf 'PASS APIM ingress is reachable and authentication is enforced\n'
else
  printf 'ERROR expected unauthenticated /v1/models to return 401, received %s\n' "$status" >&2
  exit 1
fi

if [ "$RUN_DIRECT_TESTS" = true ]; then
  if ! python3 "$SCRIPT_DIR/get-gateway-token.py" \
      --no-print-token \
      --test-models \
      --test-messages \
      --model claude-opus-5; then
    printf 'ERROR authenticated APIM endpoint verification failed\n' >&2
    exit 1
  fi
  printf 'PASS authenticated APIM endpoint verification completed\n'
fi

if [ "$PROFILE_INSTALLED" = false ]; then
  exit 3
fi

printf 'PASS local Claude gateway verification completed\n'