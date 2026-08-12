// Claude Governance MVP — Key Vault module
// Stores the Foundry (Anthropic) API key as a secret and grants APIM's
// system-assigned managed identity read-only access to it via RBAC.
//
// WHY THIS EXISTS: the Foundry/Anthropic resource for this pilot lives in a
// completely separate Microsoft Entra tenant with no B2B/federation trust
// configured, and the only credential available is a project API key. Cross-
// tenant managed-identity authentication is not possible without additional
// Entra federation, so the original managed-identity-only design (see
// modules/rbac.bicep, now unused) does not apply here. Storing the key in
// Key Vault and letting APIM pull it via a Key-Vault-backed named value is
// the least-privilege alternative: the key is never stored in Bicep
// parameters, ARM deployment history, or source control — it is written
// directly into the vault out-of-band via `az keyvault secret set` (see
// DEPLOYMENT-GUIDE.md), and this template only wires up the container + RBAC.
//
// Section 9.2 of mvp-architecture/Claude-Governance-MVP-Architecture.docx

@description('Azure region for the Key Vault.')
param location string

@description('Name of the Key Vault. Must be globally unique, 3-24 chars, alphanumeric + hyphen.')
param keyVaultName string

@description('Principal ID of the APIM system-assigned managed identity, granted read-only access to secrets.')
param apimPrincipalId string

@description('Name of the secret that will hold the Foundry (Anthropic) API key. Set the value out-of-band with `az keyvault secret set` — never via Bicep parameters.')
param foundryApiKeySecretName string = 'foundry-api-key'

@description('Enable purge protection. Recommended for production; defaults to false for easy MVP/pilot teardown. Some tenant policies enforce this regardless of this setting.')
param enablePurgeProtection bool = false

@description('Tags applied to the Key Vault.')
param tags object = {}

// Built-in "Key Vault Secrets User" role — read-only access to secret values,
// no ability to list/manage other vault objects (keys, certificates, access policies).
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Disabled'
  }
}

resource apimSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, apimPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
  }
}

@description('Resource ID of the Key Vault.')
output keyVaultId string = keyVault.id

@description('Name of the Key Vault.')
output keyVaultName string = keyVault.name

@description('URI of the Key Vault (with trailing slash), used to build the APIM named value secret identifier.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Name of the secret APIM expects to hold the Foundry API key.')
output foundryApiKeySecretName string = foundryApiKeySecretName
