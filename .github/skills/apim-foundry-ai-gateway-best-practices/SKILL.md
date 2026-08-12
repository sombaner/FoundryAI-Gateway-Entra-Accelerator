---
name: apim-foundry-ai-gateway-best-practices
description: >
  Best-practice checklist and troubleshooting playbook for deploying an Azure
  APIM "AI Gateway" in front of a Microsoft Foundry (Anthropic Claude) model,
  secured with Entra ID, and consumed by Claude Desktop / Claude Code. WHEN:
  designing or reviewing an APIM + Entra + Foundry integration, diagnosing 401
  "Missing or invalid access token" errors, deciding where the model allowlist
  / Foundry endpoint / Foundry API key should live, configuring Claude
  Desktop's native OAuth gateway settings, wiring APIM diagnostics/logging,
  or handing this pattern to a new environment/tenant.
license: MIT
metadata:
  author: Claude Governance MVP
  version: "1.1.0"
compatibility: Requires Azure CLI (az), an APIM instance with Entra token
  validation policies, and a Foundry (Azure AI Foundry) deployment exposing an
  Anthropic-compatible Messages API. Complements apim-iac-deploy and
  entra-iac-deploy for the IaC layer — this skill is the operational/runbook
  layer distilled from a real pilot deployment and its 401 debugging session.
---

# APIM + Foundry AI Gateway — Deployment Best Practices

Distilled from building and debugging a real pilot: Entra ID (identity) →
Azure APIM Standard v2 (AI Gateway) → Microsoft Foundry Anthropic Claude
deployment → Claude Desktop / Claude Code as clients. Use this as a checklist
when standing up a new environment, and as the first troubleshooting
reference when the gateway returns 401s.

## 1. Where things live (config map)

Don't guess — these are the authoritative locations. Confirm each one before
assuming something is broken:

| What | Where | How to check |
|---|---|---|
| Model allowlist | APIM named value `approved-model-name` (comma-separated) | `az apim nv show --service-name <apim> --resource-group <rg> --named-value-id approved-model-name` |
| Allowlist enforcement | `<choose>/<when>` block in `messages-api-policy.xml` comparing request body `model` field; also feeds the static `GET /v1/models` response | Inspect operation policy, not just the API-level policy |
| Foundry endpoint | APIM **Backend** resource (not a named value) | `az apim backend list --service-name <apim> --resource-group <rg> -o table` |
| Foundry API key | Named value, `secret: true` (e.g. `foundry-api-key`) | `az apim nv show ... --named-value-id foundry-api-key` (value is hidden once secret=true — this is expected) |
| Entra tenant/client IDs | Named values (`entra-tenant-id`, `gateway-api-client-id`, `cowork-client-id`) | Same `az apim nv show` pattern |
| Token validation rules | `validate-azure-ad-token` element in the **operation-level** policy (not global, not product) | Read the operation policy with the APIM ARM API (example below) |

**Rule of thumb:** allowlists and non-secret config → named values (plain
text, easy to diff/audit). Endpoints that are structural (protocol, host) →
Backend resources. Anything secret (API keys) → named value with
`secret: true`, ideally backed by Key Vault reference + APIM managed identity
rather than a raw pasted value.

### Cross-tenant ownership boundary

In this pilot, the Foundry account lives in a different subscription and
Entra tenant. The APIM tenant does not have Foundry control-plane access;
APIM reaches the pre-existing Anthropic endpoint only with the API key
supplied by the Foundry owner. Therefore:

- Do not search for, deploy, update, or infer the state of the Foundry
  account from the APIM subscription. A resource not appearing there is
  expected, not evidence that it is missing.
- Treat the endpoint, API key, and exact model deployment names supplied by
  the Foundry owner as an external contract. APIM owns only authentication,
  admission, discovery, quotas, telemetry, and request forwarding.
- Use APIM's managed identity only to resolve the Key Vault secret in the
  APIM tenant. The backend call itself uses `x-api-key`; it does not use
  managed identity or cross-tenant RBAC.
- Verify secret wiring without reading the secret value: confirm the named
  value has `secret: true`, a Key Vault `secretIdentifier`, and
  `keyVault.lastStatus.code == "Success"`.

Some Azure CLI versions do not expose an `az apim api operation policy show`
command. Use the management API rather than installing unrelated extensions
or assuming the policy is missing:

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/apis/<api-id>/operations/<operation-id>/policies/policy?api-version=2024-05-01" \
  --query properties.value -o tsv
```

## 2. Entra ID app registration gotchas

- **Two apps, distinct responsibilities**: `AI-Gateway-API` (the resource/API app, exposes a
  custom scope like `Inference.Invoke`) and `Claude-Cowork-Client` (the
  public client Claude Desktop/Code uses to sign in). Don't conflate them.
- Configure `Claude-Cowork-Client` as a single-tenant public client with no
  client secret. `isFallbackPublicClient: true` is needed only when the
  chosen client flow relies on public-client fallback; the registered
  mobile/desktop redirect URI and PKCE support are the controlling settings
  for the browser authorization-code flow used in this pilot.
- **`az account get-access-token --resource api://<custom-app-id>` will NOT
  work** for a custom API scope unless Azure CLI's own first-party app
  (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) has been explicitly granted access
  — it normally isn't, and you'll get `AADSTS650057: Invalid resource`. This
  is a dead end for testing; always mint tokens via the actual client app
  (MSAL device-code/interactive flow), not the Azure CLI.
- **Consent is per-user by default.** If only one user has signed in and
  consented, every other user needs either their own consent prompt or a
  tenant-wide admin consent grant. Prefer tenant-wide admin consent for the
  pilot, but treat it as a privileged deployment step and verify the grant;
  do not assume an `az ad` command succeeded merely because permissions were
  declared on the app registration.
- **Redirect URI must match exactly**, including host and path. This pilot
  registers `http://127.0.0.1/callback`; the client may bind an ephemeral
  loopback port only if Entra's public-client loopback matching rules and the
  actual authorization request permit it. If sign-in fails with
  `AADSTS50011` (redirect URI mismatch), check the exact path the client
  actually calls back on and add it verbatim — don't assume.

## 3. Token validation policy design

- Put `validate-azure-ad-token` at the **operation level**, not globally and
  not at the product level, so different operations (e.g. a static
  `GET /v1/models` vs. the real `POST /v1/messages` passthrough) can have
  independent rules if ever needed. Verify there's no silent duplicate/
  conflicting validation at a higher scope — check all three levels
  (global → product → API → operation) when troubleshooting, since APIM
  policies inherit and a `404 PoliciesConfiguration not found` at
  product/API level is *expected* (means "inherits"), not an error.
- Validate at minimum: `tenant-id`, `audience` (match the exact `aud` claim
  issued for the custom API; depending on token/app configuration this may
  be the API client ID or its `api://<gateway-api-client-id>` Application ID
  URI), and
  `client-application-ids` (restrict to the known client app id(s), e.g.
  `Claude-Cowork-Client`). Require delegated scope `Inference.Invoke` and
  extract `oid` for per-user quotas/telemetry. If the design also requires
  the `AI.Gateway.User` app role, validate the `roles` claim explicitly;
  assigning the role in Entra without checking it in APIM does not enforce
  it at the gateway. These checks prevent token confusion between apps that
  happen to share a tenant.
- **`subscriptionRequired: false`** is a valid, intentional choice for a
  pilot where Entra tokens are the only auth mechanism — don't mistake a
  missing `Ocp-Apim-Subscription-Key` for the cause of a 401 in that case
  (it would produce a distinctly different error message anyway: "Access
  denied due to missing subscription key").

## 4. Diagnostics — turn this on *before* you need it

The single highest-leverage fix from this project: **APIM's `GatewayLogs`
diagnostic category contains `LastErrorReason` for failed
`validate-azure-ad-token` executions**, but it is NOT enabled by default.
Every layer of static config (policy XML, named values, app registrations)
can look perfectly correct and you'll still get 401s with zero visibility
until this is on.

```bash
az monitor diagnostic-settings create \
  --name gateway-diag \
  --resource <apim-resource-id> \
  --workspace <log-analytics-workspace-resource-id> \
  --logs '[{"category":"GatewayLogs","enabled":true}]'
```

- Add this to the Bicep module for APIM (e.g. `infra/modules/apim.bicep`) as
  a first-class resource, not an imperative afterthought — it should exist
  from the very first deployment of any new environment.
- After enabling, allow a few minutes for propagation before assuming a
  retest will show fresh log entries.
- Query `ApiManagementGatewayLogs` in Log Analytics, filtering on
  `ResponseCode`, `IsRequestSuccess`, and `LastErrorReason`, correlated to
  the timestamp of a reproduced failing request.

## 5. 401 troubleshooting checklist (in order)

When `GET /v1/models` or `POST /v1/messages` returns 401:

1. **Confirm `GatewayLogs` diagnostics are enabled and actively logging** —
   if not, do this first; everything else is guesswork without it.
2. Reproduce the failing call, then immediately query
   `ApiManagementGatewayLogs` for `LastErrorReason`.
3. If logs are inconclusive, decode the actual token being sent (a
   `decode-token.py`-style script) and compare `tid`, `aud`, `azp`/`appid`,
   `scp`, and `ver` claims against the named values used in the policy.
   Don't assume the token is "obviously fine" — actually decode a real one.
4. Re-verify (with live `az apim` queries, not memory) that named values
   referenced by the policy have the exact values you expect — typos in a
   named value are indistinguishable from "everything else being correct."
5. Check consent: is the failing user's account the same one that
   originally consented to the app? Per-user consent gaps look identical to
   token/audience misconfiguration from the client's point of view.
6. Only after 1–5 are exhausted, suspect something structural (stale
   signing-key cache, clock skew, etc.) — these are rare in practice
   compared to consent/audience/named-value mismatches.

## 6. Model onboarding and troubleshooting

The APIM model list is admission configuration, not Foundry provisioning.
Adding a name to `approved-model-name` makes it pass policy and appear in
`GET /v1/models`; it does not create a deployment in Foundry.

For a model-name change:

1. Obtain the exact deployment names and entitlement confirmation from the
  cross-tenant Foundry owner. Do not attempt to discover or provision that
  account from the APIM tenant.
2. Update the declarative source first (`approvedModelName` in the Bicep
  parameter file), plus any client test allowlist and operator docs.
3. Build Bicep and validate the helper before changing live APIM.
4. Update the `approved-model-name` named value or deploy the reviewed Bicep.
5. Allow for APIM propagation. The management plane can show the new named
  value while a gateway node briefly serves the previous compiled value.
  Retry `GET /v1/models` until it consistently returns the intended list.
6. Test `POST /v1/messages` for each model with a real Entra access token and
  `anthropic-version: 2023-06-01`. Discovery returning 200 proves only APIM
  configuration; inference proves the cross-tenant backend contract.

Interpret failures by layer:

| Result | Meaning |
|---|---|
| `403 Model Not Entitled` | APIM allowlist does not contain the exact request model |
| `GET /v1/models` omits a newly added name | Named-value/policy propagation or source/live drift |
| Backend `404 DeploymentNotFound` | Foundry does not recognize that exact deployment name for the supplied key; contact the Foundry owner |
| Backend `401`/`403` after APIM accepted the caller | Foundry API-key secret is stale, invalid, or not entitled; check the Key Vault reference status and rotate through the owner |

Never solve a backend deployment error by searching for a same-named Foundry
resource in the APIM tenant or by silently removing an owner-approved model
from the contract. Report the backend result and resolve it with the Foundry
owner.

## 7. Claude Desktop native gateway integration

Claude Desktop has a built-in "Configure third-party inference → Gateway"
OAuth flow — prefer this over hand-rolled token scripts once it works,
since it's the standard, maintained path:

| Field | Value pattern |
|---|---|
| Gateway base URL | `https://<apim-name>.azure-api.net` |
| Client ID | The **public client** app id (`Claude-Cowork-Client`), never the API app id |
| Issuer URL | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Authorization URL | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize` |
| Token URL | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token` |
| Bearer token | **Access token** (not ID token) — APIM validates as an OAuth resource server |
| Scopes | `api://<gateway-api-client-id>/<custom-scope> offline_access` — never leave the default `openid profile email offline_access`, which won't carry the right audience |
| Credential kind | Interactive browser sign-in with authorization-code PKCE |

If sign-in fails, the two most likely causes are (a) redirect URI mismatch
(see §2) or (b) wrong/missing custom scope in the Scopes field.

## 8. IaC hygiene

- Anything created imperatively during live debugging (diagnostic settings,
  one-off named value updates, backend tweaks) must be back-ported into the
  Bicep modules before calling a deployment "done" — otherwise the next
  environment silently lacks it and you repeat the same debugging session.
- Never leave a plaintext API key in a `.env`/`.bicepparam` file long-term;
  treat that as a rotation item the moment the pilot is stable — move it to
  Key Vault with APIM's managed identity pulling the secret via a Key
  Vault-backed named value.
- Document every manual/ad hoc change in the deployment guide the moment
  you make it, with the exact `az` command used, so it can be replayed or
  converted to Bicep later without re-deriving it from memory.
- A live named-value update is incomplete until the Bicep parameter, helper
  model choices, and user-facing configuration documentation agree with it.
- Keep generated ARM output synchronized by rebuilding after Bicep changes;
  do not hand-edit generated templates.
