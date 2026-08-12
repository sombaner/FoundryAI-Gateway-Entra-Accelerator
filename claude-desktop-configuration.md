# Claude Desktop Configuration — Claude Governance MVP Pilot

Status: **The APIM authentication fix is deployed. Unauthenticated rejection
is verified; an authenticated end-to-end request still requires a pilot user to
complete the initial Entra sign-in.**

---

## 1. Deployed environment summary

| Item | Value |
|---|---|
| Azure subscription | `0b17562a-418b-4922-acd0-9a155008a84d` |
| Resource group | `rg-claude-governance` |
| Region | `eastus2` |
| APIM instance | `apim-claude-gov-pilot` (StandardV2) |
| **Gateway URL** | `https://apim-claude-gov-pilot.azure-api.net` |
| API path | `/v1` (Anthropic Messages passthrough) |
| Approved models | `claude-opus-5`, `claude-opus-4-5`, `claude-opus-4-6`, `claude-sonnet-4-6` |
| Entra tenant | `fc42bad7-5f0e-4bfe-af0a-122957fa475e` (`MngEnvMCAP978018.onmicrosoft.com`) |
| Resource app (API) | `AI-Gateway-API` — `appId = 7ed913c5-2aa0-4aa0-be7e-43bdbc6c8e2c` |
| Client app (Claude Desktop) | `Claude-Cowork-Client` — `appId = 1c27492c-f972-433c-8327-26d95dd54a18` |
| Exposed scope | `api://7ed913c5-2aa0-4aa0-be7e-43bdbc6c8e2c/Inference.Invoke` |
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

- `admin@MngEnvMCAP978018.onmicrosoft.com`
- `sombanerjee@MngEnvMCAP978018.onmicrosoft.com`

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
      "baseUrl": "https://apim-claude-gov-pilot.azure-api.net",
      "credential": {
         "kind": "interactive",
         "authFlow": "browser",
         "oidc": {
            "clientId": "1c27492c-f972-433c-8327-26d95dd54a18",
            "issuer": "https://login.microsoftonline.com/fc42bad7-5f0e-4bfe-af0a-122957fa475e/v2.0",
            "bearerTokenType": "access_token",
            "scopes": "api://7ed913c5-2aa0-4aa0-be7e-43bdbc6c8e2c/Inference.Invoke",
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
