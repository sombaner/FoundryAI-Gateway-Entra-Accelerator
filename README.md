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

## References

- [`infra/DEPLOYMENT-GUIDE.md`](infra/DEPLOYMENT-GUIDE.md) — full deployment walkthrough
- [`claude-desktop-configuration.md`](claude-desktop-configuration.md) — Claude Desktop MDM profile and first-run guide
- [`entra-apim-foundry-integration-explanation.md`](entra-apim-foundry-integration-explanation.md) — plain-language explanation of the identity and key model
- [`mvp-architecture/Claude-Governance-MVP-Architecture.docx`](mvp-architecture/Claude-Governance-MVP-Architecture.docx) — complete architecture design document
