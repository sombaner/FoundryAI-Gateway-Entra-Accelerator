---
name: entra-iac-deploy
description: >
  IaC deployment skill for the Microsoft Entra ID identity layer of the Claude
  Governance MVP. WHEN: infra/entra/entra.bicep, infra/entra/deploy-entra.sh,
  AI-Gateway-API app registration, Claude-Cowork-Client public client,
  Inference.Invoke scope, AI.Gateway.User app role, sg-claude-desktop-pilot
  security group, admin consent, Microsoft Graph Bicep extension, redirect URIs,
  deploy or validate Entra app registrations, add pilot users to the group.
license: MIT
metadata:
  author: Claude Governance MVP
  version: "1.0.0"
compatibility: Requires Azure CLI (az) with Microsoft Graph Bicep extension
  support (extensibility, experimental) OR plain az ad / Graph REST access,
  and the entra-iac-agent custom agent profile
  (.github/agents/entra-iac-agent.agent.md) for full context.
---

# Entra IaC Deploy — Identity Layer (Claude Governance MVP)

Operational skill for building, validating, and (only on explicit approval)
deploying the Microsoft Entra ID / Microsoft Graph layer defined in
`infra/entra/entra.bicep` (+ `infra/entra/bicepconfig.json`,
`infra/entra/entra.bicepparam`) with a CLI fallback at
`infra/entra/deploy-entra.sh`. Pair this with the `entra-iac-agent` custom
agent for design-contract details; this skill is the command/reference
cheat sheet.

> **Hard rule inherited from `iac-deployment-agent`**: never execute a Graph
> mutation (`az deployment ... create`, `deploy-entra.sh`, or direct
> `az rest`/`az ad` calls with side effects) without an explicit, current-turn
> instruction to deploy. Producing/editing the Bicep or script is always
> fine.

## Design contract (Section 3 of the MVP architecture doc)

Two app registrations only (Claude Code CLI onboarding is a Phase 2 item —
do not add a third app registration unless explicitly asked):

| App registration | Type | Purpose |
|---|---|---|
| `AI-Gateway-API` | Resource app, single-tenant | Defines the API audience; delegated scope `Inference.Invoke` (needs admin consent); app role `AI.Gateway.User` (Users/Groups); `accessTokenAcceptedVersion = 2`; enterprise app requires user assignment |
| `Claude-Cowork-Client` | Public client, single-tenant | **No client secret** (PKCE). Redirect URI `http://127.0.0.1/callback` (mobile/desktop). Delegated permission `AI-Gateway-API / Inference.Invoke` with tenant-wide admin consent |

Plus one security group `sg-claude-desktop-pilot`, assigned to the
`AI.Gateway.User` app role on the `AI-Gateway-API` enterprise application.
Add pilot users **directly** to this group — Entra does not flatten nested
groups for enterprise app role assignment.

Token contract enforced downstream by APIM (coordinate with
`apim-iac-deploy` skill / `apim-iac-agent` before changing): `tid` = tenant
ID, `aud` = AI-Gateway-API app ID URI, `scp` contains `Inference.Invoke`,
`oid` = per-user tracking key, `azp`/`appid` = Claude-Cowork-Client app ID,
`roles` contains `AI.Gateway.User`.

## Two implementation paths

### Path A — Microsoft Graph Bicep extension (preferred, declarative)

```bash
cd infra/entra

# Compile check — 1 known-benign BCP036 warning on `relationships` is
# expected (stale type definition in the experimental Graph extension;
# contradicted by the officially published schema). Not a real defect.
az bicep build --file entra.bicep

# Deploy — targets the tenant via Microsoft Graph, requires
# Application.ReadWrite.All / Group.ReadWrite.All (or Global Administrator /
# Application Administrator + Groups Administrator).
az deployment sub create \
  --location eastus2 \
  --name entra-claude-governance-mvp \
  --template-file entra.bicep \
  --parameters entra.bicepparam
```

### Path B — CLI/Graph fallback (no Bicep extensibility required)

```bash
cd infra/entra
chmod +x deploy-entra.sh   # already executable
./deploy-entra.sh
```

Idempotent (safe to re-run); uses the **same fixed GUIDs** as `entra.bicep`
(`INFERENCE_INVOKE_SCOPE_ID`, `GATEWAY_USER_APPROLE_ID`) so both paths stay
interchangeable. Prints `gatewayApiClientId`, `coworkClientId`,
`pilotGroupId`, and `gatewayApiServicePrincipalId` at the end — copy these
into `infra/main.bicepparam`.

Always state which path you used and why; keep both in sync with the
design contract if one changes.

## Rules

1. Never create a client secret for `Claude-Cowork-Client` — it's a public
   client (PKCE-only).
2. Tenant-wide admin consent for `Inference.Invoke` is a manual step
   requiring Global Administrator / Privileged Role Administrator if it
   can't be automated in the tenant's policy — call this out explicitly.
3. Never execute a Graph mutation without a fresh, explicit deploy
   instruction in the current turn.
4. Search for existing app registrations first
   (`az ad app list --display-name AI-Gateway-API` /
   `--display-name Claude-Cowork-Client`) before creating new ones, to avoid
   duplicates.
5. Hand off pure ARM/Bicep concerns (APIM named values mirroring these
   client/tenant IDs, RBAC on Foundry) to the `apim-iac-deploy` skill /
   `apim-iac-agent` / `iac-deployment-agent` — this skill's scope stops at
   the Microsoft Graph boundary.
6. Conditional Access is recommended in **report-only** mode from day one
   (MFA for Claude-Cowork-Client, prefer broker sign-in, block legacy auth)
   — do not flip to enforced without explicit instruction, and confirm
   Entra ID P1/P2 licensing first.

## Rollback

```bash
az ad app delete --id <gatewayApiClientId>
az ad app delete --id <coworkClientId>
az ad group delete --group <pilotGroupId>
```
