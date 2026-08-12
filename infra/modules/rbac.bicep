// Claude Governance MVP — RBAC module
// Grants the APIM system-assigned managed identity a least-privilege role on
// the existing Microsoft Foundry (Cognitive Services / AI Services) resource.
// Section 9.2 of mvp-architecture/Claude-Governance-MVP-Architecture.docx
// No API keys/connection strings are used anywhere in this stack.
//
// *** DEPRECATED / UNUSED FOR THIS PILOT ***
// This module is NOT referenced by main.bicep. It assumed the Foundry
// resource is reachable from the same Microsoft Entra tenant as the APIM
// deployment, so a cross-RG role assignment (or even cross-tenant, if B2B
// federation existed) could grant managed-identity access directly.
//
// In this deployment, the actual Foundry/Anthropic resource lives in a
// completely SEPARATE Entra tenant with no federation trust configured, and
// only an API key is available — there is no principal in this tenant that
// can be granted a role on a resource in the other tenant. See
// modules/keyvault.bicep + modules/apim-policy.bicep for the API-key-via-
// Key-Vault approach actually wired up in main.bicep.
//
// Kept here for reference / for a future SAME-TENANT Foundry integration,
// where this managed-identity approach is preferable to API keys.

@description('Principal ID of the APIM system-assigned managed identity.')
param apimPrincipalId string

@description('Name (not full resource ID) of the existing Foundry (Cognitive Services / AI Services) account. This resource is pre-existing and is not created/modified here.')
param foundryResourceName string

@description('Built-in role to grant. Defaults to "Cognitive Services User"; set to azureAiUser to use "Azure AI User" instead — either is acceptable per the design doc.')
@allowed([
  'cognitiveServicesUser'
  'azureAiUser'
])
param roleChoice string = 'cognitiveServicesUser'

var roleDefinitionIds = {
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  azureAiUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
}

// This module is deployed by main.bicep with an explicit `scope:` pointing at
// the resource group that actually contains the Foundry resource (which may
// differ from rg-claude-governance). Because of that, a plain same-scope
// `existing` reference by name is sufficient here — no cross-RG split()/scope
// gymnastics needed inside this file.
resource foundryResourceRef 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryResourceName
}

resource apimToFoundryRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryResourceRef.id, apimPrincipalId, roleDefinitionIds[roleChoice])
  scope: foundryResourceRef
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds[roleChoice])
  }
}

@description('Resource ID of the role assignment created.')
output roleAssignmentId string = apimToFoundryRoleAssignment.id
