# FoundryAI Gateway + Entra Accelerator

> **Status: PILOT DEPLOYED** — APIM `apim-claude-gov-pilot` is live in resource group `rg-claude-governance` (Azure subscription `0b17562a-418b-4922-acd0-9a155008a84d`, region `eastus2`).

---

## Purpose

This accelerator bootstraps a **governed, enterprise-grade AI gateway** that lets corporate users access Anthropic Claude models through **Claude Desktop**, authenticated with their existing **Microsoft Entra (Azure AD) identities**, and proxied through **Azure API Management (APIM)**. No API keys are ever distributed to end users.

The primary goals are:

| Goal | How it is met |
|---|---|
| **Identity-based access control** | Microsoft Entra app roles / security groups gate who may call the gateway. |
| **Zero-secret client configuration** | Claude Desktop uses an interactive OIDC/PKCE browser flow — users sign in with their work account, no key distribution needed. |
| **Secure backend credential management** | The Foundry API key lives only in Azure Key Vault; APIM retrieves it at runtime via its system-assigned managed identity. |
| **Model allowlisting** | An APIM policy rejects requests targeting models not in the approved list before they ever reach Foundry. |
| **Per-user token quotas** | APIM enforces configurable per-user rate and quota limits, returning `429` with `Retry-After` when exceeded. |
| **Full observability** | Every request is logged to Application Insights (Log Analytics workspace) with the caller's Entra Object ID, requested model, latency, and status code. |

---

## Architecture Overview

```
Claude Desktop (user device)
        │
        │  ****** (Entra OIDC access_token)
        ▼
Azure API Management  ─── JWT validation ──► Microsoft Entra
   (apim-claude-gov-pilot)                    (AI-Gateway-API audience,
        │                                      Inference.Invoke scope,
        │  Key Vault–backed API key (x-api-key)  AI.Gateway.User role check)
        ▼
Microsoft Foundry / Anthropic Claude endpoint
   (ai-ssattiraju-foundry, separate Entra tenant)
```

### Two-door security model

- **Door 1 — Entra (user-facing):** APIM validates the caller's Entra token before touching the AI backend.  Unauthenticated or unauthorised requests are rejected at APIM (`401` / `403`).
- **Door 2 — Key Vault–backed API key (machine-facing):** APIM's managed identity retrieves the Foundry API key from Key Vault and injects it as the `x-api-key` header. End users never see this key.

Because the Foundry resource lives in a **separate Entra tenant** (no federation), managed-identity passthrough to Foundry is not possible; the Key Vault pattern is the deliberate solution.

---

## Repository Layout

```
.
├── infra/
│   ├── main.bicep                   # Orchestrator — wires all modules together
│   ├── main.bicepparam              # Deployment parameters (fill TODOs before deploying)
│   ├── modules/
│   │   ├── observability.bicep      # Log Analytics workspace + Application Insights
│   │   ├── apim.bicep               # APIM Standard v2, system-assigned managed identity, JWT validation
│   │   ├── apim-policy.bicep        # APIM API + product + policy + Key Vault–backed named value
│   │   ├── keyvault.bicep           # Key Vault + RBAC role assignment (APIM → Key Vault Secrets User)
│   │   └── rbac.bicep               # (Reference only — original managed-identity design, not used by main.bicep)
│   ├── policies/
│   │   ├── messages-api-policy.xml  # POST /v1/messages — JWT check, model allowlist, quota, backend call
│   │   └── models-api-policy.xml    # GET /v1/models — JWT check, static approved-model list
│   ├── entra/
│   │   ├── entra.bicep              # Entra app registrations, scope, app role, security group (Graph extension)
│   │   ├── entra.bicepparam         # Entra parameters (pilot group members, etc.)
│   │   └── deploy-entra.sh          # CLI fallback — same Entra objects, no Bicep extensibility required
│   ├── claude-desktop/
│   │   ├── claude-gateway.mobileconfig         # macOS MDM profile for Claude Desktop gateway config
│   │   └── managed-settings.example.json       # Equivalent JSON for Intune / other MDMs
│   ├── scripts/
│   │   └── verify-claude-gateway.sh            # Post-deployment smoke-test script
│   ├── azure.env.example            # Placeholder for environment variables (real file is git-ignored)
│   └── DEPLOYMENT-GUIDE.md          # Step-by-step deployment and configuration guide
├── mvp-architecture/
│   ├── Claude-Governance-MVP-Architecture.docx  # Full architecture design document
│   └── architecture-diagram.png                 # Visual architecture diagram
├── claude-desktop-configuration.md              # Claude Desktop MDM profile setup and first-run guide
├── entra-apim-foundry-integration-explanation.md # Plain-language explanation of the identity model
├── APIM-FOUNDRY-CLAUDE-PORTAL-IMPLEMENTATION-GUIDE.md  # Extended implementation reference
└── README.md                                    # This file
```

---

## Key Components

### Azure API Management (APIM Standard v2)
- Exposes `POST /v1/messages` and `GET /v1/models` under the path `/v1`.
- Validates the caller's Entra bearer token (audience, issuer, scope `Inference.Invoke`, app role `AI.Gateway.User`).
- Enforces a comma-separated model allowlist before forwarding to Foundry.
- Enforces per-user token quotas and logs all requests with Entra identity metadata.
- Uses a Key Vault–backed named value to inject the Foundry `x-api-key` header.

### Microsoft Entra ID
- **`AI-Gateway-API`** — resource application that exposes the `Inference.Invoke` delegated scope and the `AI.Gateway.User` app role.
- **`Claude-Cowork-Client`** — public client application (PKCE, no secret) registered for Claude Desktop's interactive browser sign-in.
- **`sg-claude-desktop-pilot`** — Entra security group (or direct app-role assignment) that controls who may access the gateway.

### Azure Key Vault
- Stores the Foundry API key as secret `foundry-api-key`.
- APIM's system-assigned managed identity holds the **Key Vault Secrets User** role.
- The key is **never** a Bicep parameter, ARM deployment history entry, or client-side credential.

### Observability (Log Analytics + Application Insights)
- Every APIM request emits structured logs including caller OID, model name, HTTP status, and duration.
- KQL queries or Azure Monitor workbooks provide per-user and per-model usage reporting.

---

## Quick Start

> **Prerequisites:** Azure CLI, Bicep CLI (`az bicep upgrade`), and an existing Microsoft Foundry account with a Claude model deployment.

### 1. Deploy Entra identity layer

```bash
cd infra/entra
./deploy-entra.sh          # idempotent; prints gatewayApiClientId and coworkClientId
```

### 2. Fill in parameters

Edit `infra/main.bicepparam` — replace every `TODO` with values from step 1 and your Foundry endpoint URL.

### 3. Validate and deploy APIM/Key Vault/Observability

```bash
cd infra
az bicep build --file main.bicep
az deployment group validate --resource-group rg-claude-governance --template-file main.bicep --parameters main.bicepparam
az deployment group what-if  --resource-group rg-claude-governance --template-file main.bicep --parameters main.bicepparam
# Review what-if output, then:
az deployment group create   --resource-group rg-claude-governance --template-file main.bicep --parameters main.bicepparam
```

### 4. Store the Foundry API key (out-of-band, never via Bicep)

```bash
az keyvault secret set --vault-name <kv-name> --name foundry-api-key --value "<your-foundry-api-key>"
```

### 5. Configure Claude Desktop

Install the macOS MDM profile:

```bash
open infra/claude-desktop/claude-gateway.mobileconfig
```

Then sign in with your Entra work account on first launch.

For full step-by-step instructions, see [`infra/DEPLOYMENT-GUIDE.md`](infra/DEPLOYMENT-GUIDE.md) and [`claude-desktop-configuration.md`](claude-desktop-configuration.md).

---

## Approved Claude Models (pilot)

| Model |
|---|
| `claude-opus-5` |
| `claude-opus-4-5` |
| `claude-opus-4-6` |
| `claude-sonnet-4-6` |

To add or remove models, update the `approvedModelName` parameter (comma-separated) and redeploy the APIM layer — no changes to Entra or Key Vault are needed.

---

## User Management

| Action | How |
|---|---|
| Add a pilot user | Assign the `AI.Gateway.User` app role to the user on `AI-Gateway-API` (or add to `sg-claude-desktop-pilot` when group-assignable roles are available) |
| Remove a pilot user | Remove the app role assignment / group membership |
| Rotate the Foundry API key | `az keyvault secret set` with the new value; APIM picks it up automatically — no redeploy |

---

## Security Notes

- The `infra/azure.env` file is **git-ignored**; `infra/azure.env.example` contains only placeholders. Never commit real credentials.
- Both Foundry API keys that were previously exposed locally must be rotated in your Foundry portal.
- Key Vault public network access is disabled in the pilot; run `az keyvault secret set` from an approved network or a trusted deployment runner.
- Unauthenticated requests are rejected at APIM with `401` before Foundry is ever contacted.

---

# Claude Desktop Configuration — Claude Governance MVP Pilot

Status: **The APIM authentication fix is deployed. Unauthenticated rejection
is verified; an authenticated end-to-end request still requires a pilot user to
complete the initial Entra sign-in.**

---

## 1. Deployed environment summary

| Item | Value |
|---|---|
| Azure subscription | `<Azure Subscriptions>` |
| Resource group | `<rg-resource-group>` |
| Region | `eastus2` |
| APIM instance | `<instance-name>` (StandardV2) |
| **Gateway URL** | `<gateway-url>` |
| API path | `/v1` (Anthropic Messages passthrough) |
| Approved models | `claude-opus-5`, `claude-opus-4-5`, `claude-opus-4-6`, `claude-sonnet-4-6` |
| Entra tenant | `<entra-tenant>' |
| Resource app (API) | `AI-Gateway-API` — `appId = <appid>` |
| Client app (Claude Desktop) | `Claude-Cowork-Client` — `appId = <clientid>18` |
| Exposed scope | `api://<id>/Inference.Invoke` |
| App role required | `AI.Gateway.User` (assigned directly to pilot users — see §4) |
| Redirect URI (public client) | `http://127.0.0.1/callback` |

Smoke tests confirmed:
- `POST /v1/messages` with no/invalid token → `401` ✅
- `GET /v1/models` with no/invalid token → `401` ✅ (returns the approved-model list once authenticated)

The `401` is generated while the client is connecting **to APIM**. It is not an
APIM-to-Foundry error: token validation runs before APIM selects or calls the
Foundry backend.

---

## 2. Pilot users

Directly assigned the `AI.Gateway.User` app role on `AI-Gateway-API` (tenant
does not support group-assignable app roles on this app registration tier, so
per-user assignment was used instead of the `sg-claude-desktop-pilot` group):

- `user1@entratenant.com`
- `user2@entratenant.com`

Only these two identities can currently authenticate successfully against the
gateway. To add more pilot users later, assign the same app role to their
user object (see `infra/entra/deploy-entra.sh` or reuse the `az ad app
role-assignment` pattern already used for these two).

---

## 3. Claude Desktop configuration

These instructions are verified against the installed macOS Claude Desktop
build `1.26832.0` (`com.anthropic.claudefordesktop`). This build supports a
managed `gateway` inference provider. It does **not** expose the previously
documented Developer/Enterprise API form, and it does not recognize the
speculative `apiProvider` JSON shape.

`claude_desktop_config.json` remains the MCP-server configuration file; do not
put inference-provider credentials in it.

### 3.1 Deploy the managed gateway profile

This repository includes two deployment artifacts:

- `infra/claude-desktop/claude-gateway.mobileconfig` is an installable macOS
   profile.
- `infra/claude-desktop/managed-settings.example.json` is the equivalent JSON
   source for Intune or another MDM.

For a local pilot installation, open the profile:

```bash
open infra/claude-desktop/claude-gateway.mobileconfig
```

macOS opens System Settings because configuration profiles cannot be installed
silently. Review and install **Claude Governance Gateway** under **General >
Device Management**. For managed rollout, upload the same `.mobileconfig` as a
custom macOS profile in Intune and assign it to the pilot users. The preference
payload targets `com.anthropic.claudefordesktop`.

The effective managed settings must contain:

```json
{
   "inference": {
      "provider": "gateway",
      "baseUrl": "https://<name>",
      "credential": {
         "kind": "interactive",
         "authFlow": "browser",
         "oidc": {
            "clientId": "<clientid>,
            "issuer": "https://login.microsoftonline.com/<ID>/v2.0",
            "bearerTokenType": "access_token",
            "scopes": "api://<ID>/Inference.Invoke",
            "appendOfflineAccess": true
         }
      }
   }
}
```

Use the gateway **origin** as `baseUrl`, with no trailing `/v1`. Claude appends
`/v1/models` and `/v1/messages` itself. `access_token` is required because APIM
validates an OAuth resource-server token issued for `AI-Gateway-API`. An OIDC
`id_token` would target the Claude public client and APIM would reject it.

Quit and reopen Claude Desktop after the MDM profile is installed or updated.
The normal user-level preferences and `developer_settings.json` do not provide
an inference gateway override in this build.

Confirm profile installation and APIM reachability before opening Claude:

```bash
infra/scripts/verify-claude-gateway.sh
```

Exit code `3` means the source profile and APIM are valid but macOS is still
waiting for profile approval. Re-run the command after installation.

### 3.2 First Claude sign-in

After the profile is installed, quit and reopen Claude Desktop. The gateway
provider starts a system-browser authorization-code-with-PKCE sign-in. Complete
the Entra password and MFA prompt as a pilot user. Claude stores and silently
renews the resulting credential; no API key or client secret is required.

The Entra IaC registers `http://127.0.0.1/callback`, enables public-client
operation, and grants delegated access to `Inference.Invoke`, matching Claude's
browser-flow requirements.

### 3.3 Independent CLI verification

The verifier can also test APIM independently of Claude. It uses the Python
helper's separate Keychain cache and the same browser-PKCE contract; it is not
required by the desktop profile:

```bash
python3 -m pip install msal msal-extensions requests
infra/scripts/verify-claude-gateway.sh --direct-tests
```

The command tests both endpoints: `/v1/models` validates client-to-APIM
authentication, while `/v1/messages` also proves APIM-to-Foundry routing and
Foundry authentication.

---

## 4. Manual verification still required

Profile installation and initial sign-in are OS-controlled approval and
identity-proof steps. After installing the profile and completing §3.2:

1. Run the direct checks in §3.3 and confirm two `200` responses.
2. Open Claude Desktop and send a short test message.
3. Expected: a normal response routed through APIM to Foundry, with the Entra
   identity validated and usage counted against the per-user token quota.
4. A `401` means the request reached APIM but the bearer token failed APIM's
   audience, client application, or scope checks. It is not a Foundry error.
5. A `403` means the signed-in identity lacks required authorization. Confirm
   the app-role assignment with:
   ```
   az ad app role-assignment list --id 7ed913c5-2aa0-4aa0-be7e-43bdbc6c8e2c -o table
   ```
6. A `429` is the expected per-user token-quota enforcement.
7. A `500`, `502`, or `503` after `/v1/models` succeeds points to the
   APIM-to-Foundry path, backend credential, or upstream availability.

---

## 5. Viewing usage/metrics after a successful test

Once at least one real request has gone through:

```bash
# Application Insights — request count, latency, failures
az monitor app-insights query \
  --app appi-claude-gov-pilot \
  --resource-group rg-claude-governance \
  --analytics-query "requests | where timestamp > ago(1h) | project timestamp, name, resultCode, duration"

# Custom trace metadata emitted by the policy (userOid, requestedModel)
az monitor app-insights query \
  --app appi-claude-gov-pilot \
  --resource-group rg-claude-governance \
  --analytics-query "traces | where timestamp > ago(1h) | project timestamp, message, customDimensions"
```

Or in the Azure Portal: **App Insights `appi-claude-gov-pilot` → Logs**, or
**APIM `apim-claude-gov-pilot` → Analytics** for per-product/per-subscription
call volume.

---

## 6. Outstanding items (not blocking pilot use, but tracked)

| Item | Priority | Notes |
|---|---|---|
| Rotate Foundry API keys | High | The exposed local credentials have been removed and `infra/azure.env` is ignored. Rotate both keys in Foundry, then update the APIM backend key with a new `foundry-api-key` Key Vault secret version. |
| Reconcile `deploy-entra.sh` with direct-assignment pivot | Medium | Script still assumes group-assignable app roles; document or patch to match the per-user assignment actually used. |
| Add more pilot users | Low | Straightforward — same `az ad app role-assignment create` pattern used for the two current pilot users. |


## References

- [`infra/DEPLOYMENT-GUIDE.md`](infra/DEPLOYMENT-GUIDE.md) — full deployment walkthrough
- [`claude-desktop-configuration.md`](claude-desktop-configuration.md) — Claude Desktop MDM profile and first-run guide
- [`entra-apim-foundry-integration-explanation.md`](entra-apim-foundry-integration-explanation.md) — plain-language explanation of the identity and key model
- [`mvp-architecture/Claude-Governance-MVP-Architecture.docx`](mvp-architecture/Claude-Governance-MVP-Architecture.docx) — complete architecture design document
