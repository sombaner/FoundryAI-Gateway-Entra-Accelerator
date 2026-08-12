---
name: apim-iac-deploy
description: >
  IaC deployment skill for the Azure API Management "AI Gateway" layer of the
  Claude Governance MVP. WHEN: infra/modules/apim.bicep, infra/modules/apim-policy.bicep,
  infra/policies/messages-api-policy.xml, deploy APIM Standard v2, validate/what-if
  the AI gateway, Entra token validation policy, model allowlist policy, per-user
  token quota, APIM managed identity to Foundry, APIM diagnostics/logging, verify
  gateway URL or backends after deployment.
license: MIT
metadata:
  author: Claude Governance MVP
  version: "1.0.0"
compatibility: Requires Azure CLI (az) with the Bicep extension, and the apim-iac-agent
  custom agent profile (.github/agents/apim-iac-agent.agent.md) for full context.
---

# APIM IaC Deploy — AI Gateway (Claude Governance MVP)

Operational skill for building, validating, and (only on explicit approval)
deploying the Azure API Management "AI Gateway" layer defined in
`infra/modules/apim.bicep`, `infra/modules/apim-policy.bicep`, and
`infra/policies/messages-api-policy.xml`. Pair this with the
`apim-iac-agent` custom agent for design-contract details; this skill is the
command/reference cheat sheet.

> **Hard rule inherited from `iac-deployment-agent`**: never run
> `az deployment ... create` (or anything else that mutates Azure) without an
> explicit, current-turn instruction from the user to deploy. Build, lint,
> validate, and what-if are always safe to run on request.

## Design contract (Section 5 of the MVP architecture doc)

| Aspect | Value |
|---|---|
| Tier | APIM **Standard v2**, single region (pilot scale, a few dozen users) |
| Identity | System-assigned managed identity → RBAC role assignment on Foundry (`infra/modules/rbac.bicep`) |
| API surface | Dedicated custom domain; never expose the raw Foundry hostname |
| Primary operation | `POST /v1/messages` (Anthropic Messages API passthrough) |
| Optional operation | `GET /v1/models` (client discovery) |

### Policy sequence on `/v1/messages` (do not reorder/remove without explicit instruction)

1. `<validate-azure-ad-token>` — audience `api://{{gateway-api-client-id}}`,
   client app `{{cowork-client-id}}`, tenant `{{entra-tenant-id}}`, required
   claim `scp` contains `Inference.Invoke`, failure → 401. Extract `oid` →
   `userOid`.
2. Single-model allowlist — reject 403 `permission_error` unless
   `model == "claude-pilot-approved"`.
3. `<llm-token-limit>` keyed on `user:<oid>` —
   `tokens-per-minute="30000" token-quota="5000000" token-quota-period="Monthly"`.
4. `<llm-emit-token-metric namespace="EnterpriseAI">` + metadata-only
   `<trace>` (correlationId, userOid, model). **Never log prompt/response
   content.**
5. `<set-backend-service backend-id="foundry-claude-pilot" />` +
   `<authentication-managed-identity resource="https://cognitiveservices.azure.com" />`;
   strip `Ocp-Apim-Subscription-Key` / `x-api-key` before the backend call.

Streaming: don't buffer SSE; forward `anthropic-version`/`anthropic-beta`
headers; forward timeout 5–10 minutes. Diagnostics: Application Insights,
body logging disabled, redact `Authorization`/`x-api-key`/cookies.

## Quick reference — build, validate, what-if (safe to run anytime)

```bash
cd infra

# Compile check (whole stack, since apim.bicep is a module of main.bicep)
az bicep build --file main.bicep

# Server-side validation only
az deployment group validate \
  --resource-group rg-claude-governance \
  --template-file main.bicep \
  --parameters main.bicepparam

# Preview changes — review carefully, no resources touched
az deployment group what-if \
  --resource-group rg-claude-governance \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Deploy (only after explicit user approval in the current turn)

```bash
az deployment group create \
  --resource-group rg-claude-governance \
  --name claude-gateway-mvp-$(date +%Y%m%d%H%M%S) \
  --template-file main.bicep \
  --parameters main.bicepparam
```

APIM Standard v2 provisioning typically takes 30–45 minutes.

## Post-deployment verification

```bash
# Gateway URL
az deployment group show -g rg-claude-governance -n <deployment-name> \
  --query "properties.outputs.apimGatewayUrl.value" -o tsv

# APIs and backends
az apim api list -g rg-claude-governance --service-name <apimServiceName> -o table
az apim backend list -g rg-claude-governance --service-name <apimServiceName> -o table

# Confirm managed-identity role assignment landed on the Foundry resource
az role assignment list \
  --assignee <apimPrincipalId-output> \
  --scope <foundry-resource-id> \
  -o table
```

Test the gateway end to end (after Claude Desktop or a manual token is
available) using the `azure-aigateway` skill's `az apim` verification
commands and policy fragment references (token-limit, semantic-cache,
content-safety, rate-limit-by-key).

## Rules

1. Never introduce a static API key / subscription-key backend auth path —
   only `authentication-managed-identity`.
2. Never log prompt or response body content, even for debugging; if deeper
   tracing is requested, flag the trade-off explicitly and require opt-in.
3. Keep policy XML external under `infra/policies/`, loaded via
   `loadTextContent(...)` — never inline as a Bicep string.
4. After any policy or APIM Bicep edit, re-run `az bicep build --file
   infra/main.bicep`; hand off structural Bicep issues to the
   `bicep-generator` skill / `bicep-generator-agent`.
5. Never run `az deployment ... create` without a fresh, explicit
   instruction in the same turn — that decision belongs to the user via
   `iac-deployment-agent`.
