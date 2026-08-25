// AI Gateway — Azure AI Content Safety module
// Organization-controlled prompt moderation, called by APIM's llm-content-safety
// policy through a managed-identity-authenticated backend. Local auth (keys) is
// disabled so the only way in is Entra + RBAC.

@description('Azure region for the Content Safety resource.')
param location string

@description('Name of the Content Safety account (must be globally unique for its custom subdomain).')
param contentSafetyName string

@description('Tags applied to the resource.')
param tags object = {}

@description('Principal ID of the APIM system-assigned managed identity, granted Cognitive Services User on this resource.')
param apimPrincipalId string

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource contentSafety 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: contentSafetyName
  location: location
  tags: tags
  kind: 'ContentSafety'
  sku: {
    name: 'S0'
  }
  properties: {
    // Required for token-based (Entra) auth against the data plane.
    customSubDomainName: contentSafetyName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource apimToContentSafety 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(contentSafety.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: contentSafety
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

@description('Name of the Content Safety account.')
output contentSafetyName string = contentSafety.name

@description('Resource ID of the Content Safety account.')
output contentSafetyId string = contentSafety.id

@description('Data-plane endpoint used as the APIM backend URL.')
output contentSafetyEndpoint string = contentSafety.properties.endpoint
