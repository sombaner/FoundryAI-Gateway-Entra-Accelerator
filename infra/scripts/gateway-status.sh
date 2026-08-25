#!/usr/bin/env bash
# Print current deployment + resource state for the AI gateway resource group.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./azure.env; set +a

echo "=== deployments ==="
az deployment group list -g "$AZURE_RESOURCE_GROUP" \
  --query "sort_by([].{name:name,state:properties.provisioningState,ts:properties.timestamp}, &ts)" -o table

echo
echo "=== resources in $AZURE_RESOURCE_GROUP ==="
az resource list -g "$AZURE_RESOURCE_GROUP" --query "[].{name:name,type:type,state:provisioningState}" -o table

echo
echo "=== APIM provisioning state ==="
APIM_NAME=$(az apim list -g "$AZURE_RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
if [ -n "$APIM_NAME" ]; then
  az apim show -g "$AZURE_RESOURCE_GROUP" -n "$APIM_NAME" \
    --query "{name:name,state:provisioningState,gateway:gatewayUrl,principalId:identity.principalId}" -o json
else
  echo "APIM not created yet"
fi
