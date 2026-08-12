// Claude Governance MVP — Entra ID app registrations, security group, and role assignment
// Uses the Microsoft Graph Bicep extension (preview/newer Bicep CLI required).
// Source of truth: mvp-architecture/Claude-Governance-MVP-Architecture.docx, Section 3
//
// Requires infra/entra/bicepconfig.json alongside this file (extensibility +
// microsoftGraphV1 extension reference) and a Bicep CLI/az CLI version that
// supports Bicep extensibility. If unavailable in your environment, use the
// fallback script infra/entra/deploy-entra.sh instead — it performs the same
// operations idempotently via `az ad` / Microsoft Graph CLI calls.
//
// This file creates NO client secrets: Claude-Cowork-Client is a public
// client (redirect http://127.0.0.1/callback), and AI-Gateway-API is only
// used as an audience/resource app — no credentials are minted here.

extension microsoftGraphV1

@description('Display name of the resource (audience) app registration.')
param gatewayApiAppDisplayName string = 'AI-Gateway-API'

@description('Display name of the public client app registration used by Claude Desktop.')
param coworkClientAppDisplayName string = 'Claude-Cowork-Client'

@description('Display name of the pilot security group gating access to the client app.')
param pilotGroupDisplayName string = 'sg-claude-desktop-pilot'

@description('Mail nickname for the pilot security group (no spaces).')
param pilotGroupMailNickname string = 'sg-claude-desktop-pilot'

@description('Redirect URI for the public client (PKCE, loopback per Section 4).')
param coworkClientRedirectUri string = 'http://127.0.0.1/callback'

@description('Object IDs of users to add to the pilot security group at deployment time (optional — can also be managed post-deployment via the joiner/leaver process in Section 3.5).')
param initialPilotMemberObjectIds array = []

@description('Unique name (alternate key) for the pilot security group. Immutable once set.')
param pilotGroupUniqueName string = 'sg-claude-desktop-pilot'

// A stable, well-known GUID for the custom app role and delegated scope.
// Generated once and then treated as a fixed identifier — do not regenerate
// on every deployment or existing role assignments will be orphaned.
var inferenceInvokeScopeId = 'a1b2c3d4-1111-4a2b-8c3d-000000000001'
var gatewayUserAppRoleId = 'a1b2c3d4-2222-4a2b-8c3d-000000000002'

// -----------------------------------------------------------------------
// Resource (audience) app: AI-Gateway-API
// -----------------------------------------------------------------------
resource gatewayApiApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'ai-gateway-api-mvp'
  displayName: gatewayApiAppDisplayName
  signInAudience: 'AzureADMyOrg'
  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: inferenceInvokeScopeId
        adminConsentDisplayName: 'Invoke governed inference'
        adminConsentDescription: 'Allows the calling application to invoke the governed Claude inference gateway on behalf of the signed-in user.'
        userConsentDisplayName: 'Invoke governed inference'
        userConsentDescription: 'Allows the app to send prompts to the governed Claude inference gateway on your behalf.'
        value: 'Inference.Invoke'
        type: 'User'
        isEnabled: true
      }
    ]
  }
  appRoles: [
    {
      id: gatewayUserAppRoleId
      displayName: 'AI Gateway User'
      description: 'Members of the assigned security group are entitled to use the Claude Desktop pilot inference gateway.'
      value: 'AI.Gateway.User'
      allowedMemberTypes: [
        'User'
        'Group'
      ]
      isEnabled: true
    }
  ]
}

resource gatewayApiServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: gatewayApiApp.appId
}

// Second-phase patch: identifierUris cannot reference the app's own appId
// within the same resource declaration (Bicep rejects this as a circular
// self-reference — BCP079), so it is set here in a follow-up resource once
// appId is known. The Microsoft Graph Bicep extension upserts applications
// by `uniqueName`, so this updates the same app object created above rather
// than creating a duplicate registration.
//
// This is REQUIRED: without a registered identifierUris entry matching
// "api://<appId>", Azure AD cannot resolve that resource string in a token
// request, and sign-in fails with AADSTS500011 ("resource principal ...
// was not found in the tenant") even though the app and its scope exist.
resource gatewayApiAppIdentifierUri 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'ai-gateway-api-mvp'
  displayName: gatewayApiAppDisplayName
  signInAudience: 'AzureADMyOrg'
  identifierUris: [
    'api://${gatewayApiApp.appId}'
  ]
}

// -----------------------------------------------------------------------
// Public client app: Claude-Cowork-Client (no secret — PKCE public client)
// -----------------------------------------------------------------------
resource coworkClientApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'claude-cowork-client-mvp'
  displayName: coworkClientAppDisplayName
  signInAudience: 'AzureADMyOrg'
  isFallbackPublicClient: true
  publicClient: {
    redirectUris: [
      coworkClientRedirectUri
    ]
  }
  requiredResourceAccess: [
    {
      resourceAppId: gatewayApiApp.appId
      resourceAccess: [
        {
          id: inferenceInvokeScopeId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource coworkClientServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: coworkClientApp.appId
}

// -----------------------------------------------------------------------
// Pilot security group
// -----------------------------------------------------------------------
resource pilotGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: pilotGroupUniqueName
  displayName: pilotGroupDisplayName
  mailNickname: pilotGroupMailNickname
  mailEnabled: false
  securityEnabled: true
  description: 'Pilot cohort authorized to use the Claude Desktop governed inference gateway (Section 3.4 of the MVP design doc).'
  members: {
    // Append semantics (default): each object ID is added if not already a
    // member; existing members not in this list are left untouched. Safe to
    // leave initialPilotMemberObjectIds empty and manage membership entirely
    // via the Entra portal / az ad group member add after deployment.
    relationships: [for objectId in initialPilotMemberObjectIds: {
      id: objectId
    }]
  }
}

// Assign the pilot group the AI.Gateway.User app role on the resource app's
// service principal, so Conditional Access / entitlement checks can key off
// role membership rather than raw group membership everywhere.
resource pilotGroupRoleAssignment 'Microsoft.Graph/appRoleAssignedTo@v1.0' = {
  appRoleId: gatewayUserAppRoleId
  principalId: pilotGroup.id
  resourceId: gatewayApiServicePrincipal.id
}

@description('Application (client) ID of the AI-Gateway-API resource app — use as gatewayApiClientId in infra/main.bicepparam.')
output gatewayApiClientId string = gatewayApiApp.appId

@description('Application (client) ID of the Claude-Cowork-Client public client app — use as coworkClientId in infra/main.bicepparam and in the Claude Desktop managed configuration (Section 4).')
output coworkClientId string = coworkClientApp.appId

@description('Object ID of the pilot security group.')
output pilotGroupId string = pilotGroup.id

@description('Object ID of the AI-Gateway-API service principal.')
output gatewayApiServicePrincipalId string = gatewayApiServicePrincipal.id
