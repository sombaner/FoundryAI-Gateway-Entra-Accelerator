// AI Gateway — RBAC module
// Grants the APIM system-assigned managed identity a least-privilege role on
// the existing Microsoft Foundry (Cognitive Services / AI Services) resource.
// No API keys or connection strings are used anywhere in this stack.
//
// Deployed by main.bicep with an explicit `scope:` pointing at the resource
// group that holds the Foundry account (rg-sombaner-foundry), which differs
// from the gateway's own resource group (rg-ai-gateway-layer). Same
// subscription and tenant, so an ordinary role assignment is sufficient and
// managed identity fully replaces the API-key path.

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
