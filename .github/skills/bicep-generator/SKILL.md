---
name: bicep-generator
description: >
  IaC generation/authoring skill for the Claude Governance MVP Bicep templates.
  WHEN: author or refactor Bicep modules under infra/, fix az bicep build/lint
  errors, review a template for Azure Well-Architected Framework compliance,
  add a new parameter or module, fix cross-resource-group scoping errors
  (BCP139), enforce managed identity over keys, generate main.bicep or
  infra/modules/*.bicep, structure a new Bicep module.
license: MIT
metadata:
  author: Claude Governance MVP
  version: "1.0.0"
compatibility: Requires Azure CLI (az) with Bicep. Builds on the pre-existing
  azure-iac-generator and bicep-implement ("Bicep Specialist") custom agent
  profiles in .github/agents/, and pairs with bicep-generator-agent.agent.md.
---

# Bicep Generator — Claude Governance MVP IaC

Authoring/refactoring skill for the Bicep templates under `infra/`. Use this
for **producing or fixing** Bicep — not for validating/what-if/deploying
(see the `apim-iac-deploy` and `entra-iac-deploy` skills, and the
`iac-deployment-agent` for that). Builds on the pre-existing
`azure-iac-generator.agent.md` (general multi-format IaC hub) and
`bicep-implement.agent.md` ("Bicep Specialist") agents already in this repo.

## Repo structure to follow

```
infra/
  main.bicep            # resource-group-scoped orchestrator
  main.bicepparam
  bicepconfig.json
  modules/
    observability.bicep # Log Analytics + Application Insights
    apim.bicep           # APIM Standard v2 service, system-assigned identity
    apim-policy.bicep     # API + policy (loads XML via loadTextContent)
    rbac.bicep             # APIM -> Foundry role assignment (cross-RG safe)
  policies/
    messages-api-policy.xml
  entra/                 # SEPARATE deployment surface (Microsoft Graph, not ARM)
    entra.bicep
    entra.bicepparam
    bicepconfig.json      # Microsoft Graph extension + experimental extensibility
    deploy-entra.sh        # CLI/Graph fallback, mirrors entra.bicep exactly
```

One resource-group-scoped `main.bicep` composes focused modules — one
concern per module, no god-modules. `Microsoft.Graph/*` resources never mix
into `main.bicep`; they live only in `infra/entra/entra.bicep` with their
own `bicepconfig.json`.

## Standards to enforce on every template

1. **Parameters over hardcoding** — subscription ID, resource group, region,
   resource names, SKUs, tenant ID, client IDs, Foundry resource ID/endpoint
   are always `param`s with `@description()`; safe defaults only for
   genuinely safe values (SKU name), never for IDs. Ship a companion
   `.bicepparam`, never commit real secrets into it.
2. **No secrets in Bicep** — this stack is managed-identity end-to-end
   (APIM → Foundry), so there should be no backend API keys at all. If a
   future module truly needs a secret, use `@secure()` and source it from
   Key Vault, never a plaintext parameter.
3. **Managed identity over keys** — any cross-resource auth uses
   `identity: { type: 'SystemAssigned' }` + `authentication-managed-identity`
   policy / RBAC role assignment, never connection strings or subscription
   keys.
4. **Least-privilege RBAC** — target the narrowest built-in role scoped to
   the specific resource (e.g. "Cognitive Services User" scoped to the
   Foundry resource), never subscription-/RG-wide `Contributor`/`Owner`.
5. **Tags** — every resource carries at minimum `environment: 'pilot'`/`'mvp'`
   and a project/workload tag (Section 9.1 of the design doc).
6. **Outputs** — `main.bicep` outputs what a human needs next (APIM gateway
   URL, APIM managed-identity principal ID, App Insights connection-string
   name) — never output secrets.
7. **Naming** — short, consistent resource-name parameters
   (`apimServiceName`, not ad hoc concatenation) with CAF-style prefixes
   (`apim-`, `appi-`, `log-`) where practical.
8. **Policy XML stays external** — `infra/policies/*.xml`, loaded via
   `loadTextContent(...)`, never inlined as a giant string literal.

## Known fix patterns in this repo

- **BCP139 (cross-resource-group scoping)**: when a module needs to create a
  resource (e.g. a role assignment) in a *different* resource group than the
  deployment's target RG, do the cross-RG `scope: resourceGroup(...)`
  targeting at the **module invocation** in the caller (`main.bicep`), not
  inside the module itself. See `infra/modules/rbac.bicep` +
  its invocation in `main.bicep` for the working pattern.
- **Microsoft Graph extension quirks** (`infra/entra/entra.bicep`):
  - `Microsoft.Graph/servicePrincipals@v1.0` does **not** accept
    `uniqueName` (BCP037 if you add it).
  - `Microsoft.Graph/groups@v1.0` **requires** `uniqueName` (BCP035
    warning if omitted).
  - `groups.members.relationships` is an array of `{ id: string }` objects,
    not plain ID strings — use
    `relationships: [for objectId in ids: { id: objectId }]`. A residual
    BCP036 warning here (expects `string`, got `object`) is a known,
    benign, stale-type-definition issue in the experimental extension,
    contradicted by the officially published Graph Bicep schema — don't
    chase it further.

## Workflow when asked to generate or fix Bicep

1. Re-read the relevant section of
   `mvp-architecture/Claude-Governance-MVP-Architecture.docx` before writing
   anything — never invent resources/parameters not in the design.
2. Check the official Bicep/ARM schema for the resource type (via
   `azure-mcp-bicepschema` or Microsoft Learn) rather than guessing property
   names or API versions.
3. Prefer the latest generally-available API version at authoring time.
4. Write the template, then immediately validate:
   ```bash
   az bicep build --file infra/main.bicep
   # or, for the Entra layer:
   az bicep build --file infra/entra/entra.bicep
   ```
   Fix any errors before reporting back.
5. Never run `az deployment ... create/what-if/validate` yourself from this
   skill — hand the build-clean template back to the user or the
   `apim-iac-deploy` / `entra-iac-deploy` skills / `iac-deployment-agent` for
   that step.

## Rules

1. Generate/edit templates only — never execute deployments from this
   skill.
2. Keep `Microsoft.Graph/*` resources strictly inside `infra/entra/`, never
   in the resource-group-scoped `main.bicep`.
3. Every new parameter needs a `@description()` and, where it's an ID or
   secret-adjacent value, no default.
4. Always re-run `az bicep build` after an edit and report the exact
   warning/error text back rather than silently "fixing" ambiguous
   warnings — flag genuinely benign ones (like the documented BCP036 case
   above) explicitly instead of hiding them.
