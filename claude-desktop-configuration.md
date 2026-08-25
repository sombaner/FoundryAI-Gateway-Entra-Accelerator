# Claude Desktop Configuration — Foundry AI Gateway

Status: **Gateway deployed to `rg-ai-gateway-layer` with end-to-end managed
identity to Foundry. Claude Desktop signs in interactively with Entra; no API
key or client secret exists anywhere in the path.**

---

## 1. Deployed environment summary

| Item | Value |
|---|---|
| Azure subscription | `1c8300c9-08b4-4d88-b426-3868f3b963a1` (MCAPS-Hybrid-REQ-158996-2026-sombanerjee) |
| Gateway resource group | `rg-ai-gateway-layer` |
| Foundry resource group | `rg-sombaner-foundry` (`sombaner-azure-foundry`) |
| Region | `eastus` |
| APIM instance | `apim-claude-gov-pilot-34jv55` (StandardV2) |
| **Gateway URL** | `https://apim-claude-gov-pilot-34jv55.azure-api.net` |
| Claude API path | `/v1/messages` (Anthropic Messages passthrough) |
| OpenAI API path | `/openai/v1/chat/completions` |
| Discovery | `GET /v1/models` (Entra-gated, lists both surfaces) |
| Approved models | `claude-opus-5`, `claude-sonnet-5`, `gpt-5.4` |
| Entra tenant | `16b3c013-d300-468d-ac64-7eda0820b6d3` (`fdpo.onmicrosoft.com`) |
| Resource app (API) | `AI-Gateway-API` — `appId = 930c5088-07bb-4299-ba5a-ef10074bc641` |
| Client app (Claude Desktop) | `Claude-Cowork-Client` — `appId = bd44fc38-f1d8-4551-a39e-36110a20da77` |
| Exposed scope | `api://930c5088-07bb-4299-ba5a-ef10074bc641/Inference.Invoke` |
| Pilot group | `sg-claude-desktop-pilot` — `ad526581-a820-48f8-992c-0b9f56797ae1` |
| Redirect URI (public client) | `http://127.0.0.1/callback` |
| Backend auth | APIM system-assigned managed identity → Cognitive Services User on Foundry |
| Content safety | Resource + RBAC + backend deployed; **enforcement off** (see §1.1) |

GPT-5.4 uses a separate path because the Anthropic Messages and OpenAI Chat
Completions wire formats are not interchangeable. Both surfaces sit behind the
same hostname, the same Entra validation, the same content-safety fragment, and
the same per-user token quota.

### 1.1 Content Safety status

The Content Safety account, the `Cognitive Services User` grant to the APIM
identity, and the `content-safety-backend` are all deployed. Enforcement is
currently **off** via `enableContentSafety = false`.

Reason: APIM's `llm-content-safety` policy authenticates to Content Safety
through the backend's own credentials, and backend-level managed identity did
not produce a usable token in this environment. Content Safety returned
`401 "Access denied due to invalid subscription key or wrong API endpoint"`,
and because the policy fails closed, every prompt was rejected with
`403 Request failed content safety check` — including plain "Say hello."
Tested and ruled out: audience with and without a trailing slash, backend URL
with and without a trailing slash, backend URL with and without the
`/contentsafety` segment, and RBAC propagation delay.

The only configurations known to work today use a Content Safety **API key** on
the backend, which this deployment deliberately refuses. Enabling it is a
one-line flip once that is resolved:

```bash
ENABLE_CONTENT_SAFETY=true az deployment group create \
  -g rg-ai-gateway-layer -f infra/main.bicep -p infra/main.bicepparam
```

That swaps the `content-safety-check` policy fragment from a no-op to the real
`llm-content-safety` block; neither operation policy changes. Validate with a
benign prompt **before** announcing it to pilot users, because the failure mode
is a total outage rather than a degraded path.

---

## 2. Pilot users

Membership of `sg-claude-desktop-pilot` carries the `AI.Gateway.User` app role
on `AI-Gateway-API`. Add a user with:

```bash
az ad group member add --group ad526581-a820-48f8-992c-0b9f56797ae1 --member-id <user-object-id>
```

Tenant-wide admin consent for `Inference.Invoke` requires a Privileged Role
Administrator. Until it is granted, each pilot user consents once at their
first sign-in, which the scope permits (`type: User`).

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
      "baseUrl": "https://apim-claude-gov-pilot-34jv55.azure-api.net",
      "credential": {
         "kind": "interactive",
         "authFlow": "browser",
         "oidc": {
            "clientId": "bd44fc38-f1d8-4551-a39e-36110a20da77",
            "issuer": "https://login.microsoftonline.com/16b3c013-d300-468d-ac64-7eda0820b6d3/v2.0",
            "bearerTokenType": "access_token",
            "scopes": "api://930c5088-07bb-4299-ba5a-ef10074bc641/Inference.Invoke",
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
