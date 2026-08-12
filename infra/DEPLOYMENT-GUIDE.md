# Claude Governance MVP — Deployment & Configuration Guide

> **Status: PILOT DEPLOYED.** APIM `apim-claude-gov-pilot`, Key Vault
> `kv-pilot-2eo6avxolh`, and their supporting resources are live in
> `rg-claude-governance`. Treat deployment commands below as maintenance or
> recovery procedures. Review `what-if` output before every `create` command.
> The source currently includes a validated, not-yet-deployed hardening change
> that adds the `Inference.Invoke` scope check to `GET /v1/models`.

Source of truth: `mvp-architecture/Claude-Governance-MVP-Architecture.docx`
(Sections 3, 4, 5, 9). Target environment:

| | |
|---|---|
| Subscription | `0b17562a-418b-4922-acd0-9a155008a84d` |
| Resource group | `rg-claude-governance` |
| Existing resource (not created here) | Your Microsoft Foundry account hosting the Claude model deployment — **lives in a separate Entra tenant** from the subscription above, API-key access only |

---

## 0. What was built in this session

| Deliverable | Location |
|---|---|
| Master IaC deployment agent | `.github/agents/iac-deployment-agent.agent.md` |
| APIM-specific IaC agent | `.github/agents/apim-iac-agent.agent.md` |
| Entra-specific IaC agent | `.github/agents/entra-iac-agent.agent.md` |
| Bicep generator agent | `.github/agents/bicep-generator-agent.agent.md` |
| (Pre-existing, reused as basis) generic IaC generator | `.github/agents/azure-iac-generator.agent.md` |
| (Pre-existing, reused as basis) Bicep implement specialist | `.github/agents/bicep-implement.agent.md` |
| Main Bicep orchestrator | `infra/main.bicep`, `infra/main.bicepparam` |
| Observability module (Log Analytics + App Insights) | `infra/modules/observability.bicep` |
| APIM module (Standard v2, system-assigned identity, JWT validation) | `infra/modules/apim.bicep` |
| APIM API + policy module (Foundry passthrough, quotas) | `infra/modules/apim-policy.bicep`, `infra/policies/messages-api-policy.xml` |
| Key Vault module (Foundry API key storage, APIM read access via RBAC) | `infra/modules/keyvault.bicep` |
| RBAC module — **deprecated/unused** for this cross-tenant pilot, kept for reference | `infra/modules/rbac.bicep` |
| Entra ID layer (Bicep, Microsoft Graph extension) | `infra/entra/entra.bicep`, `infra/entra/entra.bicepparam`, `infra/entra/bicepconfig.json` |
| Entra ID layer (CLI fallback, no Bicep extensibility required) | `infra/entra/deploy-entra.sh` |
| This guide | `infra/DEPLOYMENT-GUIDE.md` |

All Bicep files have been validated with `az bicep build` and server-side ARM
validation. The pilot was deployed previously; this guide does not authorize
an additional deployment by itself.

> **Architecture change — cross-tenant Foundry resource (read this first):**
> The Foundry/Anthropic resource for this pilot (`ai-ssattiraju-foundry`)
> lives in a **separate Microsoft Entra tenant** from the deployment
> subscription above, with no B2B/federation trust configured. That makes
> the original "managed identity only, no keys anywhere" design impossible
> for the backend call — there is no principal in this tenant that can be
> granted a role on a resource in a different tenant. The design was
> revised: the Foundry **API key is stored in a new Azure Key Vault** created
> by this stack (`infra/modules/keyvault.bicep`), and APIM's existing
> system-assigned managed identity is granted **Key Vault Secrets User** on
> it (same-tenant RBAC, which *is* possible). APIM then injects the key as
> the `x-api-key` header via a Key-Vault-backed named value
> (`infra/modules/apim-policy.bicep`) — the key is never a Bicep parameter,
> never in ARM deployment history, and never sent by the Claude Desktop
> client. `infra/modules/rbac.bicep` (the old managed-identity-to-Foundry
> approach) is no longer used by `main.bicep`; it's kept only as reference
> for a future same-tenant Foundry integration.

> **Naming note to confirm with you:** the architecture doc and this IaC
> target **Claude Desktop** (native OIDC sign-in, PKCE public client,
> `Claude-Cowork-Client` app registration) per Section 4. If by "Claude
> Code" you meant the separate Claude Code CLI/IDE product, that is
> explicitly out of scope for this MVP (Section 1.2, deferred to Phase 2)
> and would need its own client app registration and CLI-specific redirect
> URI — let me know if you want that added now instead of / in addition to
> Claude Desktop.

---

## 1. One-time environment setup

```bash
# Confirm you're on the right subscription
az account show --query "{name:name, id:id}" -o table
az account set --subscription 0b17562a-418b-4922-acd0-9a155008a84d

# Confirm/create the target resource group (only if it doesn't exist yet)
az group show --name rg-claude-governance -o table || \
  az group create --name rg-claude-governance --location eastus2

# Bicep CLI (needed for both infra/main.bicep and infra/entra/entra.bicep)
az bicep version
az bicep upgrade   # optional but recommended; tested against 0.33.93+
```

---

## 2. Configure parameters (edit these files before anything else)

### 2.1 `infra/entra/entra.bicepparam`

All values have sensible defaults; the only thing you may want to change
is `initialPilotMemberObjectIds` (Entra object IDs, not UPNs/emails) if you
want pilot users added at deployment time instead of afterward.

### 2.2 `infra/main.bicepparam`

Replace every `TODO` placeholder:

| Parameter | Where to get the value |
|---|---|
| `apimPublisherName` / `apimPublisherEmail` | Your org name / a monitored mailbox |
| `entraTenantId` | Already set to the verified tenant GUID for this subscription; confirm with `az account show --query tenantId -o tsv` |
| `gatewayApiClientId` | Output of the Entra deployment (`gatewayApiClientId`, Step 3) |
| `coworkClientId` | Output of the Entra deployment (`coworkClientId`, Step 3) |
| `foundryEndpointUrl` | Your Foundry Anthropic Messages API base URL, **must end in `/v1`** — e.g. `https://ai-ssattiraju-foundry.services.ai.azure.com/anthropic/v1`. APIM appends only the operation path (`/messages`) to this, so omitting `/v1` causes every call to 404. |
| `approvedModelName` | The exact model name your Foundry deployment uses, e.g. `claude-opus-4-5` — must match what Claude Desktop sends in the `model` field |
| `foundryApiKeySecretName` | Leave as `foundry-api-key` unless you have a naming convention to follow |
| `location` | Region with both APIM StandardV2 and your Foundry resource available |

> **The Foundry API key itself is never a parameter here.** It is set
> directly into Key Vault after deployment (Step 4.1 below) via
> `az keyvault secret set`, which is never captured in Bicep parameter
> files, ARM deployment history, or this repo.

---

## 3. Deploy the Entra ID layer (identity + group + role)

This must run **before** step 4, because `main.bicep` needs
`gatewayApiClientId` / `coworkClientId` as inputs.

### Option A — Bicep + Microsoft Graph extension (preferred)

> Uses an **experimental** Bicep feature (`extensibility`). Fine for a
> pilot; do not rely on it for production without re-validating against
> current Bicep release notes.

```bash
cd infra/entra

# 1. Compiles the Graph-extension Bicep to ARM/extensibility JSON — catches
#    syntax errors early. One benign warning is expected and safe to ignore
#    (see "Known warnings" below).
az bicep build --file entra.bicep

# 2. Deploy — this uses Microsoft Graph, so it targets your tenant, not a
#    resource group. Requires Application.ReadWrite.All / Group.ReadWrite.All
#    (or Global Administrator / Application Administrator + Groups
#    Administrator roles) on your signed-in account.
az deployment sub create \
  --location eastus2 \
  --name entra-claude-governance-mvp \
  --template-file entra.bicep \
  --parameters entra.bicepparam
```

If your Bicep CLI/tenant doesn't support the Microsoft Graph extension
(subscription-scope deployment target, extensibility feature not
enabled, etc.), use Option B instead — it performs the identical
operations, idempotently, via plain `az ad` / Graph REST calls.

### Option B — CLI fallback script (no Bicep extensibility needed)

```bash
cd infra/entra
chmod +x deploy-entra.sh   # already executable, but harmless to re-run
./deploy-entra.sh
```

The script is idempotent (safe to re-run) and prints, at the end:

```
gatewayApiClientId (AI-Gateway-API appId):        <copy this>
coworkClientId (Claude-Cowork-Client appId):      <copy this>
pilotGroupId (sg-claude-desktop-pilot object id): <copy this>
gatewayApiServicePrincipalId:                     <copy this>
```

### Record the outputs

Whichever option you used, copy `gatewayApiClientId` and `coworkClientId`
into `infra/main.bicepparam` before proceeding to Step 4.

### Known warnings (Option A only)

- `BCP036` on the `pilotGroup.members.relationships` array: the cached
  Bicep type definitions for the experimental Microsoft Graph extension
  are looser than the published Microsoft Graph schema (confirmed against
  `learn.microsoft.com/graph/templates/bicep/reference/groups`, which
  documents `relationships` as an array of `{ id: string }` objects — the
  form used here). This is a benign, documented type-definition
  inaccuracy in the experimental extension, not a functional issue; the
  build still succeeds (exit code 0).

---

## 4. Validate → what-if → (stop) → deploy the APIM/observability/RBAC layer

Run these **in order**, from the `infra/` directory. Each step is safe to
run repeatedly and makes no changes on its own.

```bash
cd infra

# 1. Compile check
az bicep build --file main.bicep

# 2. Server-side validation (catches parameter/schema errors, no resources touched)
az deployment group validate \
  --resource-group rg-claude-governance \
  --template-file main.bicep \
  --parameters main.bicepparam

# 3. What-if — review this output carefully before going further
az deployment group what-if \
  --resource-group rg-claude-governance \
  --template-file main.bicep \
  --parameters main.bicepparam
```

**Stop here.** Review the `what-if` diff. It should show creates for:
Log Analytics workspace, Application Insights, the APIM service, a Key
Vault, one role assignment (APIM → Key Vault, "Key Vault Secrets User"),
and an APIM API + product + policy + named values. Nothing should show as
a *delete* or *replace* — if it does, do not proceed; investigate first.

```bash
# 4. Only run this once you (the user) explicitly say "go ahead and deploy":
az deployment group create \
  --resource-group rg-claude-governance \
  --name claude-gateway-mvp-$(date +%Y%m%d%H%M%S) \
  --template-file main.bicep \
  --parameters main.bicepparam
```

> APIM StandardV2 provisioning typically takes **30–45 minutes**. This is
> normal — the deployment command will block until it completes.

---

## 4.1 Set the Foundry API key in Key Vault (required, out-of-band)

This step is **not** part of the Bicep deployment on purpose — it must be
run by you, directly, so the key is never captured in Bicep parameters,
ARM deployment history, or source control.

```bash
# Get the Key Vault name from the deployment output
KV_NAME=$(az deployment group show -g rg-claude-governance -n <deployment-name> \
  --query "properties.outputs.keyVaultName.value" -o tsv)

# Set the secret directly — replace <your-foundry-api-key> with the real key
# from your Foundry resource's Keys and Endpoint page (never paste it into
# chat, a file in this repo, or any Bicep parameter). Run this from a host
# that can reach the Key Vault data plane.
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name foundry-api-key \
  --value "<your-foundry-api-key>"
```

The deployed pilot vault currently has public network access disabled. A local
CLI request from an unapproved workstation will fail with
`ForbiddenByConnection`. Run the command from an approved private-link network
or a trusted deployment runner. If an emergency rotation requires a temporary
firewall exception, approve it explicitly, restrict it to the operator's public
IP, perform the rotation, and restore public access to disabled immediately.
Do not weaken the vault network policy merely to simplify routine rotation.

APIM's named value (`foundry-api-key`) resolves this secret automatically
via the unversioned Key Vault URI
`https://<vault>.vault.azure.net/secrets/foundry-api-key`, so no APIM restart
or redeploy is needed. If you rotate the key, re-run `az keyvault secret set`
with the new value; APIM will pick up the latest version within its refresh
interval.

Verify APIM's reference status without retrieving the secret value:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/rg-claude-governance/providers/Microsoft.ApiManagement/service/<apim-name>/namedValues/foundry-api-key?api-version=2024-05-01" \
  --query "{secretIdentifier:properties.keyVault.secretIdentifier,lastStatus:properties.keyVault.lastStatus}" \
  -o json
```

Require `lastStatus.code` to be `Success` after the refresh interval. This
query returns only reference metadata and does not disclose the key.

> **Security note:** The plaintext `infra/azure.env` file has been deleted,
> `.gitignore` now excludes it, and `infra/azure.env.example` contains only
> placeholders. Both previously exposed Foundry keys must still be rotated;
> deleting the local copies does not revoke them.

---

## 5. Post-deployment verification

```bash
# Gateway URL and backend
az deployment group show -g rg-claude-governance -n <deployment-name> \
  --query "properties.outputs.apimGatewayUrl.value" -o tsv

az apim api list -g rg-claude-governance --service-name <apimServiceName> -o table
az apim backend list -g rg-claude-governance --service-name <apimServiceName> -o table

# Confirm APIM's managed identity has access to Key Vault
KV_NAME=$(az deployment group show -g rg-claude-governance -n <deployment-name> \
  --query "properties.outputs.keyVaultName.value" -o tsv)
az role assignment list \
  --assignee <apimPrincipalId-output> \
  --scope $(az keyvault show --name "$KV_NAME" --query id -o tsv) \
  -o table

# Confirm the secret is set (do not print --value in shared terminals/logs)
az keyvault secret list --vault-name "$KV_NAME" -o table
```

In the Azure Portal, open **Application Insights → Logs** and confirm the
workspace/instance exist (no traffic yet, since nothing has called the
gateway). A basic usage workbook can be added once real traffic starts
flowing (Section 5.6 of the design doc — not part of this MVP's initial
Bicep, can be added incrementally).

---

## 6. Configure Claude Desktop (Section 4 of the design doc)

### 6.1 Prerequisites

- `AI-Gateway-API` and `Claude-Cowork-Client` app registrations exist
  (Step 3 above).
- APIM custom domain is published and reachable (or use the default
  `azure-api.net` gateway URL from Step 5 for the pilot).
- Claude Desktop is installed on the pilot user's device.

### 6.2 Managed configuration

Fill in the three placeholders using values collected above, then apply
via Claude Desktop's supported managed-configuration mechanism for your
OS (macOS/Windows commonly encode this as a JSON string in a managed
preferences profile — validate with Claude Desktop's own configuration
tooling before distributing, even to a single pilot device):

```json
{
  "inferenceProvider": "gateway",
  "inferenceCredentialKind": "interactive",
  "inferenceGatewayBaseUrl": "https://<apimGatewayUrl-output-or-custom-domain>",
  "inferenceGatewayOidcAuthFlow": "broker",
  "inferenceGatewayOidc": {
    "clientId": "<coworkClientId>",
    "issuer": "https://login.microsoftonline.com/<entraTenantId>/v2.0",
    "bearerTokenType": "access_token",
    "scopes": "api://<gatewayApiClientId>/Inference.Invoke",
    "appendOfflineAccess": true
  },
  "inferenceModels": ["claude-opus-4-5"]
}
```

### 6.3 Redirect URIs (already registered in `entra.bicep` / `deploy-entra.sh`)

- Browser PKCE fallback: `http://127.0.0.1/callback`
- Broker mode (preferred where supported):
  `ms-appx-web://Microsoft.AAD.BrokerPlugin/<coworkClientId>` and
  `msauth.com.anthropic.claudefordesktop://auth`

### 6.4 First-run verification checklist

1. Launch Claude Desktop; confirm it prompts an **Entra** sign-in (not a
   Claude.ai login).
2. Sign in as a pilot user who is a member of `sg-claude-desktop-pilot`.
3. Send a short test message; confirm a normal response.
4. In Application Insights, confirm a logged request with the expected
   `oid` (object ID), client ID, model, and a 200 status.
5. Sign in as a user **not** in the pilot group; confirm the request is
   rejected with 403.
6. Temporarily lower the per-user token quota to a very small number,
   exhaust it, and confirm a 429 with `Retry-After` is returned.

---

## 7. Rollback / cleanup (if you need to tear the pilot down)

```bash
# Remove the resource-group-scoped resources
az deployment group delete -g rg-claude-governance -n <deployment-name>
az resource list -g rg-claude-governance -o table   # confirm empty / expected

# Remove Entra objects (Option A or B, whichever you used to create them)
az ad app delete --id <gatewayApiClientId>
az ad app delete --id <coworkClientId>
az ad group delete --group <pilotGroupId>
```

---

## Summary of what still requires your explicit go-ahead

Nothing has been deployed. Before any real Azure/Entra changes happen, you
need to:

1. Fill in the remaining `TODO` placeholders in `infra/main.bicepparam`
   (publisher name/email, region, `gatewayApiClientId`/`coworkClientId`
   after Step 3).
2. Explicitly tell the agent/session to run Step 3 (Entra) and Step 4
   (`what-if` then `create`) — the custom agents in `.github/agents/`
   are hard-coded to refuse to run any `create` command without a fresh,
   explicit instruction in the same turn (see `iac-deployment-agent.agent.md`
   rule 1).
3. After deployment, run Step 4.1 yourself to set the real Foundry API key
   in Key Vault — this is intentionally never automated through Bicep.
4. Rotate both API keys currently sitting in plaintext in `infra/azure.env`
   (they've now been exposed in this chat/session) and delete or relocate
   that file once Key Vault is populated.
5. Confirm whether "Claude Code" in your original request meant Claude
   Desktop (what this MVP builds) or the separate Claude Code CLI/IDE
   product (Phase 2, deferred per Section 1.2).
